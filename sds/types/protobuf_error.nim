import results

type
  ProtoError* {.pure.} = enum
    ## Low-level protobuf wire decode errors surfaced by the field codec in
    ## `sds/protobufutil.nim`.
    VarintDecode
    MessageIncomplete
    BufferOverflow
    BadWireType
    IncorrectBlob
    RequiredFieldMissing

  ProtoResult*[T] = Result[T, ProtoError]

  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      error*: ProtoError
    of MissingRequiredField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

proc init*(T: type ProtobufError, error: ProtoError): T =
  return T(kind: ProtobufErrorKind.DecodeFailure, error: error)

proc init*(T: type ProtobufError, field: string): T =
  return T(kind: ProtobufErrorKind.MissingRequiredField, field: field)
