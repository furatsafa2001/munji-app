import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Patient to caregiver linking.
///
/// Creating and ending a link always goes through Cloud Functions, because
/// the link is what Firestore rules use to decide who may read a patient's
/// data. The app only *reads* `careLinks`, filtered to the signed-in user.
class LinkService {
  LinkService({FirebaseFunctions? functions, FirebaseFirestore? db})
      : _fn = functions ?? FirebaseFunctions.instanceFor(region: region),
        _db = db ?? FirebaseFirestore.instance;

  /// Same region as Firestore and every other function.
  static const region = 'me-central1';

  final FirebaseFunctions _fn;
  final FirebaseFirestore _db;

  /// Patient: a new six-digit code. Any earlier code stops working.
  Future<LinkCode> generate() async {
    final res = await _call('linkCodeGenerate', const {});
    return LinkCode(
      code: res['code'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (res['expiresAt'] as num).toInt()),
    );
  }

  /// Caregiver: redeem a code. Returns the patient's name.
  Future<String> redeem(String code, {String? relation}) async {
    final res = await _call('linkCodeRedeem', {
      'code': code,
      if (relation != null) 'relation': relation,
    });
    return (res['patientName'] as String?) ?? '';
  }

  /// Either side: end the link.
  Future<void> revoke({required String patientId, required String caregiverId}) =>
      _call('linkRevoke', {'patientId': patientId, 'caregiverId': caregiverId});

  /// Active links where the signed-in user is the patient.
  Stream<List<CareLink>> forPatient(String uid) => _db
      .collection('careLinks')
      .where('patientId', isEqualTo: uid)
      .where('status', isEqualTo: 'active')
      .snapshots()
      .map(_toLinks);

  /// Active links where the signed-in user is the caregiver.
  Stream<List<CareLink>> forCaregiver(String uid) => _db
      .collection('careLinks')
      .where('caregiverId', isEqualTo: uid)
      .where('status', isEqualTo: 'active')
      .snapshots()
      .map(_toLinks);

  List<CareLink> _toLinks(QuerySnapshot<Map<String, dynamic>> s) {
    final list = s.docs.map((d) => CareLink.fromMap(d.data())).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return list;
  }

  Future<Map<String, dynamic>> _call(String name, Map<String, dynamic> data) async {
    try {
      final r = await _fn.httpsCallable(name).call<Map<String, dynamic>>(data);
      return Map<String, dynamic>.from(r.data);
    } on FirebaseFunctionsException catch (e) {
      throw LinkException(LinkException.reasonFrom(e.code, e.message));
    }
  }
}

class LinkCode {
  const LinkCode({required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;
}

class CareLink {
  const CareLink({
    required this.patientId,
    required this.caregiverId,
    required this.patientName,
    required this.caregiverName,
    required this.relation,
    required this.priority,
    required this.activatedAt,
  });

  factory CareLink.fromMap(Map<String, dynamic> m) => CareLink(
        patientId: m['patientId'] as String,
        caregiverId: m['caregiverId'] as String,
        patientName: (m['patientName'] as String?) ?? '',
        caregiverName: (m['caregiverName'] as String?) ?? '',
        relation: m['relation'] as String?,
        priority: (m['priority'] as num?)?.toInt() ?? 1,
        activatedAt: (m['activatedAt'] as Timestamp?)?.toDate(),
      );

  final String patientId;
  final String caregiverId;
  final String patientName;
  final String caregiverName;
  final String? relation;
  final int priority;
  final DateTime? activatedAt;
}

enum LinkReason {
  invalidCode,
  tooManyAttempts,
  alreadyLinked,
  tooManyCaregivers,
  wrongRole,
  verifyEmail,
  unavailable,
  unknown,
}

class LinkException implements Exception {
  const LinkException(this.reason);
  final LinkReason reason;

  static LinkReason reasonFrom(String code, String? message) {
    switch (message) {
      case 'invalid-code':
      case 'bad-code':
        return LinkReason.invalidCode;
      case 'too-many-attempts':
        return LinkReason.tooManyAttempts;
      case 'already-linked':
        return LinkReason.alreadyLinked;
      case 'too-many-caregivers':
        return LinkReason.tooManyCaregivers;
      case 'not-patient':
      case 'not-caregiver':
        return LinkReason.wrongRole;
      case 'verify-email':
        return LinkReason.verifyEmail;
    }
    // The functions are not deployed to me-central2 until CNTXT billing is
    // set up, so a release build lands here.
    if (code == 'unavailable' || code == 'not-found' || code == 'internal') {
      return LinkReason.unavailable;
    }
    return LinkReason.unknown;
  }

  String message(bool ar) {
    switch (reason) {
      case LinkReason.invalidCode:
        return ar
            ? 'الرمز غير صحيح أو انتهت صلاحيته. اطلب رمزًا جديدًا من المريض.'
            : 'The code is wrong or has expired. Ask the patient for a new one.';
      case LinkReason.tooManyAttempts:
        return ar
            ? 'محاولات كثيرة. انتظر 15 دقيقة ثم حاول مجددًا.'
            : 'Too many attempts. Wait 15 minutes and try again.';
      case LinkReason.alreadyLinked:
        return ar ? 'أنت مرتبط بهذا المريض مسبقًا.' : 'You are already linked to this patient.';
      case LinkReason.tooManyCaregivers:
        return ar
            ? 'وصل المريض للحد الأقصى من المرافقين (5).'
            : 'This patient already has the maximum of 5 caregivers.';
      case LinkReason.wrongRole:
        return ar ? 'هذا الإجراء غير متاح لنوع حسابك.' : 'Not available for your account type.';
      case LinkReason.verifyEmail:
        return ar ? 'أكّد بريدك الإلكتروني أولًا.' : 'Verify your email first.';
      case LinkReason.unavailable:
        return ar
            ? 'خدمة الربط غير متاحة حاليًا. حاول لاحقًا.'
            : 'Linking is not available right now. Try again later.';
      case LinkReason.unknown:
        return ar ? 'حدث خطأ. حاول مجددًا.' : 'Something went wrong. Try again.';
    }
  }
}

/// Relation labels, in the order the caregiver sees them.
const relations = ['son', 'daughter', 'spouse', 'sibling', 'parent', 'friend', 'other'];

String relationLabel(String? r, bool ar) {
  switch (r) {
    case 'son':
      return ar ? 'ابن' : 'Son';
    case 'daughter':
      return ar ? 'ابنة' : 'Daughter';
    case 'spouse':
      return ar ? 'زوج / زوجة' : 'Spouse';
    case 'sibling':
      return ar ? 'أخ / أخت' : 'Sibling';
    case 'parent':
      return ar ? 'أب / أم' : 'Parent';
    case 'friend':
      return ar ? 'صديق' : 'Friend';
    case 'other':
      return ar ? 'أخرى' : 'Other';
    default:
      return ar ? 'مرافق' : 'Caregiver';
  }
}
