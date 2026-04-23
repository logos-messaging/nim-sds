# adapted from https://github.com/waku-org/nwaku/blob/master/waku/common/protobuf.nim

{.push raises: [].}

import libp2p/protobuf/minprotobuf
import libp2p/varint
import ./types/protobuf_error

export minprotobuf, varint, protobuf_error

converter toProtobufError*(err: minprotobuf.ProtoError): ProtobufError =
  case err
  of minprotobuf.ProtoError.RequiredFieldMissing:
    return ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: "unknown")
  else:
    return ProtobufError(kind: ProtobufErrorKind.DecodeFailure, error: err)

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  return ProtobufError.init(field)
