import std/json
import ./json_base_event

type JsonPeriodicSyncEvent* = ref object of JsonEvent

proc new*(T: type JsonPeriodicSyncEvent): T =
  return JsonPeriodicSyncEvent(eventType: "periodic_sync")

method `$`*(jsonPeriodicSync: JsonPeriodicSyncEvent): string {.raises: [].} =
  $(%*jsonPeriodicSync)
