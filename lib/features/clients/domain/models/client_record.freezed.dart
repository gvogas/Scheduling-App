// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'client_record.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ClientContact {

 String get name; String get phone; String get email;
/// Create a copy of ClientContact
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ClientContactCopyWith<ClientContact> get copyWith => _$ClientContactCopyWithImpl<ClientContact>(this as ClientContact, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ClientContact;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ClientContact&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.phone, _this.phone) || other.phone == _this.phone)&&(identical(other.email, _this.email) || other.email == _this.email));
}


@override
int get hashCode {
  final _this = this as ClientContact;
  return Object.hash(runtimeType,_this.name,_this.phone,_this.email);
}

@override
String toString() {
  final _this = this as ClientContact;
  return 'ClientContact(name: ${_this.name}, phone: ${_this.phone}, email: ${_this.email})';
}


}

/// @nodoc
abstract mixin class $ClientContactCopyWith<$Res>  {
  factory $ClientContactCopyWith(ClientContact value, $Res Function(ClientContact) _then) = _$ClientContactCopyWithImpl;
@useResult
$Res call({
 String name, String phone, String email
});




}
/// @nodoc
class _$ClientContactCopyWithImpl<$Res>
    implements $ClientContactCopyWith<$Res> {
  _$ClientContactCopyWithImpl(this._self, this._then);

  final ClientContact _self;
  final $Res Function(ClientContact) _then;

/// Create a copy of ClientContact
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? phone = null,Object? email = null,}) {
  return _then(ClientContact(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ClientContact].
extension ClientContactPatterns on ClientContact {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ClientContact value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ClientContact() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ClientContact value)  $default,){
final _that = this;
switch (_that) {
case _ClientContact():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ClientContact value)?  $default,){
final _that = this;
switch (_that) {
case _ClientContact() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String phone,  String email)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ClientContact() when $default != null:
return $default(_that.name,_that.phone,_that.email);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String phone,  String email)  $default,) {final _that = this;
switch (_that) {
case _ClientContact():
return $default(_that.name,_that.phone,_that.email);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String phone,  String email)?  $default,) {final _that = this;
switch (_that) {
case _ClientContact() when $default != null:
return $default(_that.name,_that.phone,_that.email);case _:
  return null;

}
}

}

/// @nodoc


class _ClientContact extends ClientContact {
  const _ClientContact({this.name = '', this.phone = '', this.email = ''}): super._();
  

@override@JsonKey() final  String name;
@override@JsonKey() final  String phone;
@override@JsonKey() final  String email;

/// Create a copy of ClientContact
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ClientContactCopyWith<_ClientContact> get copyWith => __$ClientContactCopyWithImpl<_ClientContact>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ClientContact&&(identical(other.name, name) || other.name == name)&&(identical(other.phone, phone) || other.phone == phone)&&(identical(other.email, email) || other.email == email));
}


@override
int get hashCode {
    return Object.hash(runtimeType,name,phone,email);
}

@override
String toString() {
    return 'ClientContact(name: $name, phone: $phone, email: $email)';
}


}

/// @nodoc
abstract mixin class _$ClientContactCopyWith<$Res> implements $ClientContactCopyWith<$Res> {
  factory _$ClientContactCopyWith(_ClientContact value, $Res Function(_ClientContact) _then) = __$ClientContactCopyWithImpl;
@override @useResult
$Res call({
 String name, String phone, String email
});




}
/// @nodoc
class __$ClientContactCopyWithImpl<$Res>
    implements _$ClientContactCopyWith<$Res> {
  __$ClientContactCopyWithImpl(this._self, this._then);

  final _ClientContact _self;
  final $Res Function(_ClientContact) _then;

/// Create a copy of ClientContact
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? phone = null,Object? email = null,}) {
  return _then(_ClientContact(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$ClientRecord {

 String get id; String get name; String get firstName; String get lastName; String get address; String get apt; String get city; String get province; String get country; String get postalCode; String get phone; String get mobile; String get email; List<ClientContact> get contacts; bool get noFixedAddress; bool get archived; ClientType get type; String get accessNotes; String get onSiteManager; String get billingTerms; bool get autoInvoice; String get businessName; int? get jobCount; DateTime? get createdAt; String? get waveCustomerId; String get waveSyncState; String? get waveSyncError; List<WaveProblem> get waveProblems;
/// Create a copy of ClientRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ClientRecordCopyWith<ClientRecord> get copyWith => _$ClientRecordCopyWithImpl<ClientRecord>(this as ClientRecord, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ClientRecord;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ClientRecord&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.firstName, _this.firstName) || other.firstName == _this.firstName)&&(identical(other.lastName, _this.lastName) || other.lastName == _this.lastName)&&(identical(other.address, _this.address) || other.address == _this.address)&&(identical(other.apt, _this.apt) || other.apt == _this.apt)&&(identical(other.city, _this.city) || other.city == _this.city)&&(identical(other.province, _this.province) || other.province == _this.province)&&(identical(other.country, _this.country) || other.country == _this.country)&&(identical(other.postalCode, _this.postalCode) || other.postalCode == _this.postalCode)&&(identical(other.phone, _this.phone) || other.phone == _this.phone)&&(identical(other.mobile, _this.mobile) || other.mobile == _this.mobile)&&(identical(other.email, _this.email) || other.email == _this.email)&&const DeepCollectionEquality().equals(other.contacts, _this.contacts)&&(identical(other.noFixedAddress, _this.noFixedAddress) || other.noFixedAddress == _this.noFixedAddress)&&(identical(other.archived, _this.archived) || other.archived == _this.archived)&&(identical(other.type, _this.type) || other.type == _this.type)&&(identical(other.accessNotes, _this.accessNotes) || other.accessNotes == _this.accessNotes)&&(identical(other.onSiteManager, _this.onSiteManager) || other.onSiteManager == _this.onSiteManager)&&(identical(other.billingTerms, _this.billingTerms) || other.billingTerms == _this.billingTerms)&&(identical(other.autoInvoice, _this.autoInvoice) || other.autoInvoice == _this.autoInvoice)&&(identical(other.businessName, _this.businessName) || other.businessName == _this.businessName)&&(identical(other.jobCount, _this.jobCount) || other.jobCount == _this.jobCount)&&(identical(other.createdAt, _this.createdAt) || other.createdAt == _this.createdAt)&&(identical(other.waveCustomerId, _this.waveCustomerId) || other.waveCustomerId == _this.waveCustomerId)&&(identical(other.waveSyncState, _this.waveSyncState) || other.waveSyncState == _this.waveSyncState)&&(identical(other.waveSyncError, _this.waveSyncError) || other.waveSyncError == _this.waveSyncError)&&const DeepCollectionEquality().equals(other.waveProblems, _this.waveProblems));
}


@override
int get hashCode {
  final _this = this as ClientRecord;
  return Object.hashAll([runtimeType,_this.id,_this.name,_this.firstName,_this.lastName,_this.address,_this.apt,_this.city,_this.province,_this.country,_this.postalCode,_this.phone,_this.mobile,_this.email,const DeepCollectionEquality().hash(_this.contacts),_this.noFixedAddress,_this.archived,_this.type,_this.accessNotes,_this.onSiteManager,_this.billingTerms,_this.autoInvoice,_this.businessName,_this.jobCount,_this.createdAt,_this.waveCustomerId,_this.waveSyncState,_this.waveSyncError,const DeepCollectionEquality().hash(_this.waveProblems)]);
}

@override
String toString() {
  final _this = this as ClientRecord;
  return 'ClientRecord(id: ${_this.id}, name: ${_this.name}, firstName: ${_this.firstName}, lastName: ${_this.lastName}, address: ${_this.address}, apt: ${_this.apt}, city: ${_this.city}, province: ${_this.province}, country: ${_this.country}, postalCode: ${_this.postalCode}, phone: ${_this.phone}, mobile: ${_this.mobile}, email: ${_this.email}, contacts: ${_this.contacts}, noFixedAddress: ${_this.noFixedAddress}, archived: ${_this.archived}, type: ${_this.type}, accessNotes: ${_this.accessNotes}, onSiteManager: ${_this.onSiteManager}, billingTerms: ${_this.billingTerms}, autoInvoice: ${_this.autoInvoice}, businessName: ${_this.businessName}, jobCount: ${_this.jobCount}, createdAt: ${_this.createdAt}, waveCustomerId: ${_this.waveCustomerId}, waveSyncState: ${_this.waveSyncState}, waveSyncError: ${_this.waveSyncError}, waveProblems: ${_this.waveProblems})';
}


}

/// @nodoc
abstract mixin class $ClientRecordCopyWith<$Res>  {
  factory $ClientRecordCopyWith(ClientRecord value, $Res Function(ClientRecord) _then) = _$ClientRecordCopyWithImpl;
@useResult
$Res call({
 String id, String name, String firstName, String lastName, String address, String apt, String city, String province, String country, String postalCode, String phone, String mobile, String email, List<ClientContact> contacts, bool noFixedAddress, bool archived, ClientType type, String accessNotes, String onSiteManager, String billingTerms, bool autoInvoice, String businessName, int? jobCount, DateTime? createdAt, String? waveCustomerId, String waveSyncState, String? waveSyncError, List<WaveProblem> waveProblems
});




}
/// @nodoc
class _$ClientRecordCopyWithImpl<$Res>
    implements $ClientRecordCopyWith<$Res> {
  _$ClientRecordCopyWithImpl(this._self, this._then);

  final ClientRecord _self;
  final $Res Function(ClientRecord) _then;

/// Create a copy of ClientRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? firstName = null,Object? lastName = null,Object? address = null,Object? apt = null,Object? city = null,Object? province = null,Object? country = null,Object? postalCode = null,Object? phone = null,Object? mobile = null,Object? email = null,Object? contacts = null,Object? noFixedAddress = null,Object? archived = null,Object? type = null,Object? accessNotes = null,Object? onSiteManager = null,Object? billingTerms = null,Object? autoInvoice = null,Object? businessName = null,Object? jobCount = freezed,Object? createdAt = freezed,Object? waveCustomerId = freezed,Object? waveSyncState = null,Object? waveSyncError = freezed,Object? waveProblems = null,}) {
  return _then(ClientRecord(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,firstName: null == firstName ? _self.firstName : firstName // ignore: cast_nullable_to_non_nullable
as String,lastName: null == lastName ? _self.lastName : lastName // ignore: cast_nullable_to_non_nullable
as String,address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,apt: null == apt ? _self.apt : apt // ignore: cast_nullable_to_non_nullable
as String,city: null == city ? _self.city : city // ignore: cast_nullable_to_non_nullable
as String,province: null == province ? _self.province : province // ignore: cast_nullable_to_non_nullable
as String,country: null == country ? _self.country : country // ignore: cast_nullable_to_non_nullable
as String,postalCode: null == postalCode ? _self.postalCode : postalCode // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,mobile: null == mobile ? _self.mobile : mobile // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,contacts: null == contacts ? _self.contacts : contacts // ignore: cast_nullable_to_non_nullable
as List<ClientContact>,noFixedAddress: null == noFixedAddress ? _self.noFixedAddress : noFixedAddress // ignore: cast_nullable_to_non_nullable
as bool,archived: null == archived ? _self.archived : archived // ignore: cast_nullable_to_non_nullable
as bool,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ClientType,accessNotes: null == accessNotes ? _self.accessNotes : accessNotes // ignore: cast_nullable_to_non_nullable
as String,onSiteManager: null == onSiteManager ? _self.onSiteManager : onSiteManager // ignore: cast_nullable_to_non_nullable
as String,billingTerms: null == billingTerms ? _self.billingTerms : billingTerms // ignore: cast_nullable_to_non_nullable
as String,autoInvoice: null == autoInvoice ? _self.autoInvoice : autoInvoice // ignore: cast_nullable_to_non_nullable
as bool,businessName: null == businessName ? _self.businessName : businessName // ignore: cast_nullable_to_non_nullable
as String,jobCount: freezed == jobCount ? _self.jobCount : jobCount // ignore: cast_nullable_to_non_nullable
as int?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,waveCustomerId: freezed == waveCustomerId ? _self.waveCustomerId : waveCustomerId // ignore: cast_nullable_to_non_nullable
as String?,waveSyncState: null == waveSyncState ? _self.waveSyncState : waveSyncState // ignore: cast_nullable_to_non_nullable
as String,waveSyncError: freezed == waveSyncError ? _self.waveSyncError : waveSyncError // ignore: cast_nullable_to_non_nullable
as String?,waveProblems: null == waveProblems ? _self.waveProblems : waveProblems // ignore: cast_nullable_to_non_nullable
as List<WaveProblem>,
  ));
}

}


/// Adds pattern-matching-related methods to [ClientRecord].
extension ClientRecordPatterns on ClientRecord {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ClientRecord value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ClientRecord() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ClientRecord value)  $default,){
final _that = this;
switch (_that) {
case _ClientRecord():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ClientRecord value)?  $default,){
final _that = this;
switch (_that) {
case _ClientRecord() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String firstName,  String lastName,  String address,  String apt,  String city,  String province,  String country,  String postalCode,  String phone,  String mobile,  String email,  List<ClientContact> contacts,  bool noFixedAddress,  bool archived,  ClientType type,  String accessNotes,  String onSiteManager,  String billingTerms,  bool autoInvoice,  String businessName,  int? jobCount,  DateTime? createdAt,  String? waveCustomerId,  String waveSyncState,  String? waveSyncError,  List<WaveProblem> waveProblems)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ClientRecord() when $default != null:
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.address,_that.apt,_that.city,_that.province,_that.country,_that.postalCode,_that.phone,_that.mobile,_that.email,_that.contacts,_that.noFixedAddress,_that.archived,_that.type,_that.accessNotes,_that.onSiteManager,_that.billingTerms,_that.autoInvoice,_that.businessName,_that.jobCount,_that.createdAt,_that.waveCustomerId,_that.waveSyncState,_that.waveSyncError,_that.waveProblems);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String firstName,  String lastName,  String address,  String apt,  String city,  String province,  String country,  String postalCode,  String phone,  String mobile,  String email,  List<ClientContact> contacts,  bool noFixedAddress,  bool archived,  ClientType type,  String accessNotes,  String onSiteManager,  String billingTerms,  bool autoInvoice,  String businessName,  int? jobCount,  DateTime? createdAt,  String? waveCustomerId,  String waveSyncState,  String? waveSyncError,  List<WaveProblem> waveProblems)  $default,) {final _that = this;
switch (_that) {
case _ClientRecord():
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.address,_that.apt,_that.city,_that.province,_that.country,_that.postalCode,_that.phone,_that.mobile,_that.email,_that.contacts,_that.noFixedAddress,_that.archived,_that.type,_that.accessNotes,_that.onSiteManager,_that.billingTerms,_that.autoInvoice,_that.businessName,_that.jobCount,_that.createdAt,_that.waveCustomerId,_that.waveSyncState,_that.waveSyncError,_that.waveProblems);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String firstName,  String lastName,  String address,  String apt,  String city,  String province,  String country,  String postalCode,  String phone,  String mobile,  String email,  List<ClientContact> contacts,  bool noFixedAddress,  bool archived,  ClientType type,  String accessNotes,  String onSiteManager,  String billingTerms,  bool autoInvoice,  String businessName,  int? jobCount,  DateTime? createdAt,  String? waveCustomerId,  String waveSyncState,  String? waveSyncError,  List<WaveProblem> waveProblems)?  $default,) {final _that = this;
switch (_that) {
case _ClientRecord() when $default != null:
return $default(_that.id,_that.name,_that.firstName,_that.lastName,_that.address,_that.apt,_that.city,_that.province,_that.country,_that.postalCode,_that.phone,_that.mobile,_that.email,_that.contacts,_that.noFixedAddress,_that.archived,_that.type,_that.accessNotes,_that.onSiteManager,_that.billingTerms,_that.autoInvoice,_that.businessName,_that.jobCount,_that.createdAt,_that.waveCustomerId,_that.waveSyncState,_that.waveSyncError,_that.waveProblems);case _:
  return null;

}
}

}

/// @nodoc


class _ClientRecord extends ClientRecord {
  const _ClientRecord({required this.id, this.name = '', this.firstName = '', this.lastName = '', this.address = '', this.apt = '', this.city = '', this.province = '', this.country = '', this.postalCode = '', this.phone = '', this.mobile = '', this.email = '',  List<ClientContact> contacts = const <ClientContact>[], this.noFixedAddress = false, this.archived = false, this.type = ClientType.unset, this.accessNotes = '', this.onSiteManager = '', this.billingTerms = '', this.autoInvoice = false, this.businessName = '', this.jobCount = null, this.createdAt, this.waveCustomerId = null, this.waveSyncState = '', this.waveSyncError = null,  List<WaveProblem> waveProblems = const <WaveProblem>[]}): _contacts = contacts,_waveProblems = waveProblems,super._();
  

@override final  String id;
@override@JsonKey() final  String name;
@override@JsonKey() final  String firstName;
@override@JsonKey() final  String lastName;
@override@JsonKey() final  String address;
@override@JsonKey() final  String apt;
@override@JsonKey() final  String city;
@override@JsonKey() final  String province;
@override@JsonKey() final  String country;
@override@JsonKey() final  String postalCode;
@override@JsonKey() final  String phone;
@override@JsonKey() final  String mobile;
@override@JsonKey() final  String email;
 final  List<ClientContact> _contacts;
@override@JsonKey() List<ClientContact> get contacts {
  if (_contacts is EqualUnmodifiableListView) return _contacts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_contacts);
}

@override@JsonKey() final  bool noFixedAddress;
@override@JsonKey() final  bool archived;
@override@JsonKey() final  ClientType type;
@override@JsonKey() final  String accessNotes;
@override@JsonKey() final  String onSiteManager;
@override@JsonKey() final  String billingTerms;
@override@JsonKey() final  bool autoInvoice;
@override@JsonKey() final  String businessName;
@override@JsonKey() final  int? jobCount;
@override final  DateTime? createdAt;
@override@JsonKey() final  String? waveCustomerId;
@override@JsonKey() final  String waveSyncState;
@override@JsonKey() final  String? waveSyncError;
 final  List<WaveProblem> _waveProblems;
@override@JsonKey() List<WaveProblem> get waveProblems {
  if (_waveProblems is EqualUnmodifiableListView) return _waveProblems;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_waveProblems);
}


/// Create a copy of ClientRecord
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ClientRecordCopyWith<_ClientRecord> get copyWith => __$ClientRecordCopyWithImpl<_ClientRecord>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ClientRecord&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.firstName, firstName) || other.firstName == firstName)&&(identical(other.lastName, lastName) || other.lastName == lastName)&&(identical(other.address, address) || other.address == address)&&(identical(other.apt, apt) || other.apt == apt)&&(identical(other.city, city) || other.city == city)&&(identical(other.province, province) || other.province == province)&&(identical(other.country, country) || other.country == country)&&(identical(other.postalCode, postalCode) || other.postalCode == postalCode)&&(identical(other.phone, phone) || other.phone == phone)&&(identical(other.mobile, mobile) || other.mobile == mobile)&&(identical(other.email, email) || other.email == email)&&const DeepCollectionEquality().equals(other.contacts, _contacts)&&(identical(other.noFixedAddress, noFixedAddress) || other.noFixedAddress == noFixedAddress)&&(identical(other.archived, archived) || other.archived == archived)&&(identical(other.type, type) || other.type == type)&&(identical(other.accessNotes, accessNotes) || other.accessNotes == accessNotes)&&(identical(other.onSiteManager, onSiteManager) || other.onSiteManager == onSiteManager)&&(identical(other.billingTerms, billingTerms) || other.billingTerms == billingTerms)&&(identical(other.autoInvoice, autoInvoice) || other.autoInvoice == autoInvoice)&&(identical(other.businessName, businessName) || other.businessName == businessName)&&(identical(other.jobCount, jobCount) || other.jobCount == jobCount)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.waveCustomerId, waveCustomerId) || other.waveCustomerId == waveCustomerId)&&(identical(other.waveSyncState, waveSyncState) || other.waveSyncState == waveSyncState)&&(identical(other.waveSyncError, waveSyncError) || other.waveSyncError == waveSyncError)&&const DeepCollectionEquality().equals(other.waveProblems, _waveProblems));
}


@override
int get hashCode {
    return Object.hashAll([runtimeType,id,name,firstName,lastName,address,apt,city,province,country,postalCode,phone,mobile,email,const DeepCollectionEquality().hash(_contacts),noFixedAddress,archived,type,accessNotes,onSiteManager,billingTerms,autoInvoice,businessName,jobCount,createdAt,waveCustomerId,waveSyncState,waveSyncError,const DeepCollectionEquality().hash(_waveProblems)]);
}

@override
String toString() {
    return 'ClientRecord(id: $id, name: $name, firstName: $firstName, lastName: $lastName, address: $address, apt: $apt, city: $city, province: $province, country: $country, postalCode: $postalCode, phone: $phone, mobile: $mobile, email: $email, contacts: $contacts, noFixedAddress: $noFixedAddress, archived: $archived, type: $type, accessNotes: $accessNotes, onSiteManager: $onSiteManager, billingTerms: $billingTerms, autoInvoice: $autoInvoice, businessName: $businessName, jobCount: $jobCount, createdAt: $createdAt, waveCustomerId: $waveCustomerId, waveSyncState: $waveSyncState, waveSyncError: $waveSyncError, waveProblems: $waveProblems)';
}


}

/// @nodoc
abstract mixin class _$ClientRecordCopyWith<$Res> implements $ClientRecordCopyWith<$Res> {
  factory _$ClientRecordCopyWith(_ClientRecord value, $Res Function(_ClientRecord) _then) = __$ClientRecordCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String firstName, String lastName, String address, String apt, String city, String province, String country, String postalCode, String phone, String mobile, String email, List<ClientContact> contacts, bool noFixedAddress, bool archived, ClientType type, String accessNotes, String onSiteManager, String billingTerms, bool autoInvoice, String businessName, int? jobCount, DateTime? createdAt, String? waveCustomerId, String waveSyncState, String? waveSyncError, List<WaveProblem> waveProblems
});




}
/// @nodoc
class __$ClientRecordCopyWithImpl<$Res>
    implements _$ClientRecordCopyWith<$Res> {
  __$ClientRecordCopyWithImpl(this._self, this._then);

  final _ClientRecord _self;
  final $Res Function(_ClientRecord) _then;

/// Create a copy of ClientRecord
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? firstName = null,Object? lastName = null,Object? address = null,Object? apt = null,Object? city = null,Object? province = null,Object? country = null,Object? postalCode = null,Object? phone = null,Object? mobile = null,Object? email = null,Object? contacts = null,Object? noFixedAddress = null,Object? archived = null,Object? type = null,Object? accessNotes = null,Object? onSiteManager = null,Object? billingTerms = null,Object? autoInvoice = null,Object? businessName = null,Object? jobCount = freezed,Object? createdAt = freezed,Object? waveCustomerId = freezed,Object? waveSyncState = null,Object? waveSyncError = freezed,Object? waveProblems = null,}) {
  return _then(_ClientRecord(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,firstName: null == firstName ? _self.firstName : firstName // ignore: cast_nullable_to_non_nullable
as String,lastName: null == lastName ? _self.lastName : lastName // ignore: cast_nullable_to_non_nullable
as String,address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,apt: null == apt ? _self.apt : apt // ignore: cast_nullable_to_non_nullable
as String,city: null == city ? _self.city : city // ignore: cast_nullable_to_non_nullable
as String,province: null == province ? _self.province : province // ignore: cast_nullable_to_non_nullable
as String,country: null == country ? _self.country : country // ignore: cast_nullable_to_non_nullable
as String,postalCode: null == postalCode ? _self.postalCode : postalCode // ignore: cast_nullable_to_non_nullable
as String,phone: null == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String,mobile: null == mobile ? _self.mobile : mobile // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,contacts: null == contacts ? _self._contacts : contacts // ignore: cast_nullable_to_non_nullable
as List<ClientContact>,noFixedAddress: null == noFixedAddress ? _self.noFixedAddress : noFixedAddress // ignore: cast_nullable_to_non_nullable
as bool,archived: null == archived ? _self.archived : archived // ignore: cast_nullable_to_non_nullable
as bool,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ClientType,accessNotes: null == accessNotes ? _self.accessNotes : accessNotes // ignore: cast_nullable_to_non_nullable
as String,onSiteManager: null == onSiteManager ? _self.onSiteManager : onSiteManager // ignore: cast_nullable_to_non_nullable
as String,billingTerms: null == billingTerms ? _self.billingTerms : billingTerms // ignore: cast_nullable_to_non_nullable
as String,autoInvoice: null == autoInvoice ? _self.autoInvoice : autoInvoice // ignore: cast_nullable_to_non_nullable
as bool,businessName: null == businessName ? _self.businessName : businessName // ignore: cast_nullable_to_non_nullable
as String,jobCount: freezed == jobCount ? _self.jobCount : jobCount // ignore: cast_nullable_to_non_nullable
as int?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,waveCustomerId: freezed == waveCustomerId ? _self.waveCustomerId : waveCustomerId // ignore: cast_nullable_to_non_nullable
as String?,waveSyncState: null == waveSyncState ? _self.waveSyncState : waveSyncState // ignore: cast_nullable_to_non_nullable
as String,waveSyncError: freezed == waveSyncError ? _self.waveSyncError : waveSyncError // ignore: cast_nullable_to_non_nullable
as String?,waveProblems: null == waveProblems ? _self._waveProblems : waveProblems // ignore: cast_nullable_to_non_nullable
as List<WaveProblem>,
  ));
}


}

// dart format on
