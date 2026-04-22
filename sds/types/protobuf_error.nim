import results
import libp2p/protobuf/minprotobuf

type
  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      error*: minprotobuf.ProtoError
    of MissingRequiredField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

proc init*(T: type ProtobufError, error: minprotobuf.ProtoError): T =
  T(kind: ProtobufErrorKind.DecodeFailure, error: error)

proc init*(T: type ProtobufError, field: string): T =
  T(kind: ProtobufErrorKind.MissingRequiredField, field: field)
