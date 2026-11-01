SPCOMP ?= spcomp64
SCRIPTING := addons/sourcemod/scripting

$(SCRIPTING)/movementapi.smx: FORCE
	$(SPCOMP) $(SCRIPTING)/movementapi.sp -i$(SCRIPTING)/include -o$@

FORCE:
