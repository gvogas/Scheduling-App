// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'employee_record.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EmployeeRecord {

 String get id; String get name; String get firstName; String get lastName; String get email; String get phone; Color get color; String get role; String get status; String get uid; JobTitle get jobTitle; List<bool> get workingDays; int get workStartMinutes; int get workEndMinutes; int get maxJobsPerDay; bool get onCall; bool get travelAlertsEnabled; bool get locationSharingEnabled; bool get isTestAccount; bool get monthEndReviewPush; DateTime? get createdAt;
/// Create a copy of EmployeeRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EmployeeRecordCopyWith<EmployeeRecord> get copyWith => _$EmployeeRecordCopyWithImpl<EmployeeRecord>(this as EmployeeRecord, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as EmployeeRecord;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EmployeeRecord&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.firstName, _this.firstName) || other.firstName == _this.firstName)&&(identical(other.lastName, _this.lastName) || other.lastName == _this.lastName)&&(identical(other.email, _this.email) || other.email == _this.email)&&(identical(other.phone, _this.phone) || other.phone == _this.phone)&&(identical(other.color, _this.color) || other.color == _this.color)&&(identical(other.role, _this.role) || other.role == _this.role)&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.uid, _this.uid) || other.uid == _this.uid)&&(identical(other.jobTitle, _this.jobTitle) || other.jobTitle == _this.jobTitle)&&const DeepCollectionEquality().equals(other.workingDays, _this.workingDays)&&(identical(other.workStartMinutes, _this.workStartMinutes) || other.workStartMinutes == _this.workStartMinutes)&&(identical(other.workEndMinutes, _this.workEndMinutes) || other.workEndMinutes == _this.workEndMinutes)&&(identical(other.maxJobsPerDay, _this.maxJobsPerDay) || other.maxJobsPerDay == _this.maxJobsPerDay)&&(identical(other.onCall, _this.onCall) || other.onCall == _this.onCall)&&(identical(other.travelAlertsEnabled, _this.travelAlertsEnabled) || other.travelAlertsEnabled == _this.travelAlertsEnabled)&&(identical(other.locationSharingEnabled, _this.locationSharingEnabled) || other.locationSharingEnabled == _this.locationSharingEnabled)&&(identical(other.isTestAccount, _this.isTestAccount) || other.isTestAccount == _this.isTestAccount)&&(identical(other.monthEndReviewPush, _this.monthEndReviewPush) || other.monthEndReviewPush == _this.monthEndReviewPush)&&(identical(other.createdAt, _this.createdAt) || other.createdAt == _this.createdAt));
}


@override
int get hashCode {
  final _this = this as EmployeeRecord;
  return Object.hashAll([runtimeType,_this.id,_this.name,_this.firstName,_this.lastName,_this.email,_this.phone,_this.color,_this.role,_this.status,_this.uid,_this.jobTitle,const DeepCollectionEquality().hash(_this.workingDays),_this.workStartMinutes,_this.workEndMinutes,_this.maxJobsPerDay,_this.onCall,_this.travelAlertsEnabled,_this.locationSharingEnabled,_this.isTestAccount,_this.monthEndReviewPush,_this.createdAt]);
}

@override
String toString() {
  final _this = this as EmployeeRecord;
  return 'EmployeeRecord(id: ${_this.id}, name: ${_this.name}, firstName: ${_this.firstName}, lastName: ${_this.lastName}, email: ${_this.email}, phone: ${_this.phone}, color: ${_this.color}, role: ${_this.role}, status: ${_this.status}, uid: ${_this.uid}, jobTitle: ${_this.jobTitle}, workingDays: ${_this.workingDays}, workStartMinutes: ${_this.workStartMinutes}, workEndMinutes: ${_this.workEndMinutes}, maxJobsPerDay: ${_this.maxJobsPerDay}, onCall: ${_this.onCall}, travelAlertsEnabled: ${_this.travelAlertsEnabled}, locationSharingEnabled: ${_this.locationSharingEnabled}, isTestAccount: ${_this.isTestAccount}, monthEndReviewPush: ${_this.monthEndReviewPush}, createdAt: ${_this.createdAt})';
}


}

/// @nodoc
abstract mixin class $EmployeeRecordCopyWith<$Res>  {
  factory $EmployeeRecordCopyWith(EmployeeRecord value, $Res Function(EmployeeRecord) _then) = _$EmployeeRecordCopyWithImpl;
@useResult
$Res call({
 String id, String name, String firstName, String lastName, String email, String phone, Color color, String role, String status, String uid, JobTitle jobTitle, List<bool> workingDays, int workStartMinutes, int workEndMinutes, int maxJobsPerDay, bool onCall, bool travelAlertsEnabled, bool locationSharingEnabled, bool isTestAccount, bool monthEndReviewPush, DateTime? createdAt
});




}
/// @nodoc
class _$EmployeeRecordCopyWithImpl<$Res>
    implements $EmployeeRecordCopyWith<$Res> {
  _$EmployeeRecordCopyWithImpl(this._self, this._then);

  final EmployeeRecord _self;
  final $Res Function(EmployeeRecord) _then;

/// Create a copy of EmployeeRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? firstName = null,Object? lastName = null,Object? email = null,Object? phone = null,Object? color = null,Object? role = null,Object? status = null,Object? uid = null,Object? jobTitle = null,Object? workingDays = null,Object? workStartMinutes = null,Object? workEndMinutes = null,Object? maxJobsPerDay = null,Object? onCall = null,Object? travelAlertsEnabled = null,Object? locationSharingEnabled = null,Object? isTestAccount = null,Object? monthEndReviewPush = null,Object? createdAt = freezed,}) {
  return _then(EmployeeRecord(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,firstName: null == firstName ? _self.firstName : firstName // ignore: cast_nullable_to_non_nullable
as String,lastName: null == lastName ? _self.lastName : lastName // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as Color,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,uid: null == uid ? _self.uid : uid // ignore: cast_nullable_to_non_nullable
as String,jobTitle: null == jobTitle ? _self.jobTitle : jobTitle // ignore: cast_nullable_to_non_nullable
as JobTitle,workingDays: null == workingDays ? _self.workingDays : workingDays // ignore: cast_nullable_to_non_nullable
as List<bool>,workStartMinutes: null == workStartMinutes ? _self.workStartMinutes : workStartMinutes // ignore: cast_nullable_to_non_nullable
as int,workEndMinutes: null == workEndMinutes ? _self.workEndMinutes : workEndMinutes // ignore: cast_nullable_to_non_nullable
as int,maxJobsPerDay: null == maxJobsPerDay ? _self.maxJobsPerDay : maxJobsPerDay // ignore: cast_nullable_to_non_nullable
as int,onCall: null == onCall ? _self.onCall : onCall // ignore: cast_nullable_to_non_nullable
as bool,travelAlertsEnabled: null == travelAlertsEnabled ? _self.travelAlertsEnabled : travelAlertsEnabled // ignore: cast_nullable_to_non_nullable
as bool,locationSharingEnabled: null == locationSharingEnabled ? _self.locationSharingEnabled : locationSharingEnabled // ignore: cast_nullable_to_non_nullable
as bool,isTestAccount: null == isTestAccount ? _self.isTestAccount : isTestAccount // ignore: cast_nullable_to_non_nullable
as bool,monthEndReviewPush: null == monthEndReviewPush ? _self.monthEndReviewPush : monthEndReviewPush // ignore: cast_nullable_to_non_nullable
as bool,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [EmployeeRecord].
extension EmployeeRecordPatterns on EmployeeRecord {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _EmployeeRecord value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _EmployeeRecord() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _EmployeeRecord value)  $default,){
final _that = this;
switch (_that) {
case _EmployeeRecord():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _EmployeeRecord value)?  $default,){
final _that = this;
switch (_that) {
case _EmployeeRecord() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String firstName,  String lastName,  String email,  String phone,  Color color,  String role,  String status,  String uid,  JobTitle jobTitle,  List<bool> workingDays,  int workStartMinutes,  int workEndMinutes,  int maxJobsPerDay,  bool onCall,  bool travelAlertsEnabled,  bool locationSharingEnabled,  bool isTestAccount,  bool monthEndReviewPush,  DateTime? createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _EmployeeRecord() when $default != null:
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.email,_that.phone,_that.color,_that.role,_that.status,_that.uid,_that.jobTitle,_that.workingDays,_that.workStartMinutes,_that.workEndMinutes,_that.maxJobsPerDay,_that.onCall,_that.travelAlertsEnabled,_that.locationSharingEnabled,_that.isTestAccount,_that.monthEndReviewPush,_that.createdAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String firstName,  String lastName,  String email,  String phone,  Color color,  String role,  String status,  String uid,  JobTitle jobTitle,  List<bool> workingDays,  int workStartMinutes,  int workEndMinutes,  int maxJobsPerDay,  bool onCall,  bool travelAlertsEnabled,  bool locationSharingEnabled,  bool isTestAccount,  bool monthEndReviewPush,  DateTime? createdAt)  $default,) {final _that = this;
switch (_that) {
case _EmployeeRecord():
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.email,_that.phone,_that.color,_that.role,_that.status,_that.uid,_that.jobTitle,_that.workingDays,_that.workStartMinutes,_that.workEndMinutes,_that.maxJobsPerDay,_that.onCall,_that.travelAlertsEnabled,_that.locationSharingEnabled,_that.isTestAccount,_that.monthEndReviewPush,_that.createdAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String firstName,  String lastName,  String email,  String phone,  Color color,  String role,  String status,  String uid,  JobTitle jobTitle,  List<bool> workingDays,  int workStartMinutes,  int workEndMinutes,  int maxJobsPerDay,  bool onCall,  bool travelAlertsEnabled,  bool locationSharingEnabled,  bool isTestAccount,  bool monthEndReviewPush,  DateTime? createdAt)?  $default,) {final _that = this;
switch (_that) {
case _EmployeeRecord() when $default != null:
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.email,_that.phone,_that.color,_that.role,_that.status,_that.uid,_that.jobTitle,_that.workingDays,_that.workStartMinutes,_that.workEndMinutes,_that.maxJobsPerDay,_that.onCall,_that.travelAlertsEnabled,_that.locationSharingEnabled,_that.isTestAccount,_that.monthEndReviewPush,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc


class _EmployeeRecord extends EmployeeRecord {
  const _EmployeeRecord({required this.id, this.name = '', this.firstName = '', this.lastName = '', this.email = '', this.phone = '', this.color = AppColors.crewDefault, this.role = 'employee', this.status = '', this.uid = '', this.jobTitle = JobTitle.unset,  List<bool> workingDays = kDefaultWorkingDays, this.workStartMinutes = kDefaultWorkStartMinutes, this.workEndMinutes = kDefaultWorkEndMinutes, this.maxJobsPerDay = 0, this.onCall = false, this.travelAlertsEnabled = true, this.locationSharingEnabled = false, this.isTestAccount = false, this.monthEndReviewPush = false, this.createdAt}): _workingDays = workingDays,super._();
  

@override final  String id;
@override@JsonKey() final  String name;
@override@JsonKey() final  String firstName;
@override@JsonKey() final  String lastName;
@override@JsonKey() final  String email;
@override@JsonKey() final  String phone;
@override@JsonKey() final  Color color;
@override@JsonKey() final  String role;
@override@JsonKey() final  String status;
@override@JsonKey() final  String uid;
@override@JsonKey() final  JobTitle jobTitle;
 final  List<bool> _workingDays;
@override@JsonKey() List<bool> get workingDays {
  if (_workingDays is EqualUnmodifiableListView) return _workingDays;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_workingDays);
}

@override@JsonKey() final  int workStartMinutes;
@override@JsonKey() final  int workEndMinutes;
@override@JsonKey() final  int maxJobsPerDay;
@override@JsonKey() final  bool onCall;
@override@JsonKey() final  bool travelAlertsEnabled;
@override@JsonKey() final  bool locationSharingEnabled;
@override@JsonKey() final  bool isTestAccount;
@override@JsonKey() final  bool monthEndReviewPush;
@override final  DateTime? createdAt;

/// Create a copy of EmployeeRecord
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$EmployeeRecordCopyWith<_EmployeeRecord> get copyWith => __$EmployeeRecordCopyWithImpl<_EmployeeRecord>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _EmployeeRecord&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.firstName, firstName) || other.firstName == firstName)&&(identical(other.lastName, lastName) || other.lastName == lastName)&&(identical(other.email, email) || other.email == email)&&(identical(other.phone, phone) || other.phone == phone)&&(identical(other.color, color) || other.color == color)&&(identical(other.role, role) || other.role == role)&&(identical(other.status, status) || other.status == status)&&(identical(other.uid, uid) || other.uid == uid)&&(identical(other.jobTitle, jobTitle) || other.jobTitle == jobTitle)&&const DeepCollectionEquality().equals(other.workingDays, _workingDays)&&(identical(other.workStartMinutes, workStartMinutes) || other.workStartMinutes == workStartMinutes)&&(identical(other.workEndMinutes, workEndMinutes) || other.workEndMinutes == workEndMinutes)&&(identical(other.maxJobsPerDay, maxJobsPerDay) || other.maxJobsPerDay == maxJobsPerDay)&&(identical(other.onCall, onCall) || other.onCall == onCall)&&(identical(other.travelAlertsEnabled, travelAlertsEnabled) || other.travelAlertsEnabled == travelAlertsEnabled)&&(identical(other.locationSharingEnabled, locationSharingEnabled) || other.locationSharingEnabled == locationSharingEnabled)&&(identical(other.isTestAccount, isTestAccount) || other.isTestAccount == isTestAccount)&&(identical(other.monthEndReviewPush, monthEndReviewPush) || other.monthEndReviewPush == monthEndReviewPush)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}


@override
int get hashCode {
    return Object.hashAll([runtimeType,id,name,firstName,lastName,email,phone,color,role,status,uid,jobTitle,const DeepCollectionEquality().hash(_workingDays),workStartMinutes,workEndMinutes,maxJobsPerDay,onCall,travelAlertsEnabled,locationSharingEnabled,isTestAccount,monthEndReviewPush,createdAt]);
}

@override
String toString() {
    return 'EmployeeRecord(id: $id, name: $name, firstName: $firstName, lastName: $lastName, email: $email, phone: $phone, color: $color, role: $role, status: $status, uid: $uid, jobTitle: $jobTitle, workingDays: $workingDays, workStartMinutes: $workStartMinutes, workEndMinutes: $workEndMinutes, maxJobsPerDay: $maxJobsPerDay, onCall: $onCall, travelAlertsEnabled: $travelAlertsEnabled, locationSharingEnabled: $locationSharingEnabled, isTestAccount: $isTestAccount, monthEndReviewPush: $monthEndReviewPush, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$EmployeeRecordCopyWith<$Res> implements $EmployeeRecordCopyWith<$Res> {
  factory _$EmployeeRecordCopyWith(_EmployeeRecord value, $Res Function(_EmployeeRecord) _then) = __$EmployeeRecordCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String firstName, String lastName, String email, String phone, Color color, String role, String status, String uid, JobTitle jobTitle, List<bool> workingDays, int workStartMinutes, int workEndMinutes, int maxJobsPerDay, bool onCall, bool travelAlertsEnabled, bool locationSharingEnabled, bool isTestAccount, bool monthEndReviewPush, DateTime? createdAt
});




}
/// @nodoc
class __$EmployeeRecordCopyWithImpl<$Res>
    implements _$EmployeeRecordCopyWith<$Res> {
  __$EmployeeRecordCopyWithImpl(this._self, this._then);

  final _EmployeeRecord _self;
  final $Res Function(_EmployeeRecord) _then;

/// Create a copy of EmployeeRecord
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? firstName = null,Object? lastName = null,Object? email = null,Object? phone = null,Object? color = null,Object? role = null,Object? status = null,Object? uid = null,Object? jobTitle = null,Object? workingDays = null,Object? workStartMinutes = null,Object? workEndMinutes = null,Object? maxJobsPerDay = null,Object? onCall = null,Object? travelAlertsEnabled = null,Object? locationSharingEnabled = null,Object? isTestAccount = null,Object? monthEndReviewPush = null,Object? createdAt = freezed,}) {
  return _then(_EmployeeRecord(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,firstName: null == firstName ? _self.firstName : firstName // ignore: cast_nullable_to_non_nullable
as String,lastName: null == lastName ? _self.lastName : lastName // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as Color,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,uid: null == uid ? _self.uid : uid // ignore: cast_nullable_to_non_nullable
as String,jobTitle: null == jobTitle ? _self.jobTitle : jobTitle // ignore: cast_nullable_to_non_nullable
as JobTitle,workingDays: null == workingDays ? _self._workingDays : workingDays // ignore: cast_nullable_to_non_nullable
as List<bool>,workStartMinutes: null == workStartMinutes ? _self.workStartMinutes : workStartMinutes // ignore: cast_nullable_to_non_nullable
as int,workEndMinutes: null == workEndMinutes ? _self.workEndMinutes : workEndMinutes // ignore: cast_nullable_to_non_nullable
as int,maxJobsPerDay: null == maxJobsPerDay ? _self.maxJobsPerDay : maxJobsPerDay // ignore: cast_nullable_to_non_nullable
as int,onCall: null == onCall ? _self.onCall : onCall // ignore: cast_nullable_to_non_nullable
as bool,travelAlertsEnabled: null == travelAlertsEnabled ? _self.travelAlertsEnabled : travelAlertsEnabled // ignore: cast_nullable_to_non_nullable
as bool,locationSharingEnabled: null == locationSharingEnabled ? _self.locationSharingEnabled : locationSharingEnabled // ignore: cast_nullable_to_non_nullable
as bool,isTestAccount: null == isTestAccount ? _self.isTestAccount : isTestAccount // ignore: cast_nullable_to_non_nullable
as bool,monthEndReviewPush: null == monthEndReviewPush ? _self.monthEndReviewPush : monthEndReviewPush // ignore: cast_nullable_to_non_nullable
as bool,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
