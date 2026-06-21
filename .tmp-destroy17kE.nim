import dokime/private/runtime

type
  T = object
    x: int

proc `=destroy`(t: T) {.raises.} =
  raise BadOperation

when isMainModule:
  var t = T(x: 1)
  discard t
