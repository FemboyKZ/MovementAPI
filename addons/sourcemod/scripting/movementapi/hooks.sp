#define NON_JUMP_VELOCITY     140.0
#define STANDABLE_NORMAL_Z    0.7

#define PX_TOP_NORMAL_Z       0.999
#define PX_WALL_PROBE_DIST    40.0
#define PX_WALL_DIRS          8
#define PX_WALL_NORMAL_Z      0.3
#define PX_WALL_HALF_WIDTH    16.0
#define PX_WALL_PRESS_MARGIN  2.0
#define PX_FLOOR_PROBE_DROP   2.0
#define PX_FLOOR_PROBE_TOL    4.0

static DynamicDetour H_OnPlayerMove;
static DynamicDetour H_OnDuck;
static DynamicDetour H_OnLadderMove;
static DynamicDetour H_OnFullLadderMove;
static DynamicDetour H_OnJump;
static DynamicDetour H_OnAirAccelerate;
static DynamicDetour H_OnWalkMove;
static DynamicDetour H_OnCategorizePosition;
static DynamicDetour H_OnTryPlayerMove;
static DynamicHook H_OnTracePlayerBBox;
static int gI_TraceHookId = INVALID_HOOK_ID;
static bool gB_TraceHookAvailable;
static bool gB_TraceHookAttempted;
static Address moveHelperAddr;

static bool gB_TryPlayerMoveThisTick[MAXPLAYERS + 1];

// trace_t field offsets, 32-bit CGameTrace.
#define TRACE_STARTPOS   0
#define TRACE_ENDPOS     12
#define TRACE_NORMAL     24
#define TRACE_DIST       36
#define TRACE_FRACTION   44
#define TRACE_ALLSOLID   54

bool gB_InTryPlayerMove[MAXPLAYERS + 1];
bool gB_SeededFirstTrace[MAXPLAYERS + 1];
static float gF_SeedFirstDest[MAXPLAYERS + 1][3];
float gF_TraceDist[MAXPLAYERS + 1][MAX_BUMPS];

float gF_Origin[MAXPLAYERS + 1][3];
float gF_Velocity[MAXPLAYERS + 1][3];

bool gB_ProcessingLadderMove[MAXPLAYERS + 1];
float gF_PreLadderMoveVelocity[MAXPLAYERS + 1][3];
bool gB_TakeoffFromLadder[MAXPLAYERS + 1];
float gF_TakeoffLadderNormal[MAXPLAYERS + 1][3];
float gF_PostLadderMoveOrigin[MAXPLAYERS + 1][3];
float gF_PostLadderMoveVelocity[MAXPLAYERS + 1][3];

bool gB_ProcessingDuck[MAXPLAYERS + 1];
bool gB_Ducking[MAXPLAYERS + 1];
bool gB_PrevOnGround[MAXPLAYERS + 1];
bool gB_Duckbugged[MAXPLAYERS + 1];
float gF_PostDuckOrigin[MAXPLAYERS + 1][3];

bool gB_Jumpbugged[MAXPLAYERS + 1];

bool gB_WalkMoved[MAXPLAYERS + 1];
float gF_PostWalkMoveVelocity[MAXPLAYERS + 1][3];
float gF_PostAAOrigin[MAXPLAYERS + 1][3];
float gF_PostAAVelocity[MAXPLAYERS + 1][3];

bool gB_OldWalkMoved[MAXPLAYERS + 1];

int gI_CollisionCount[MAXPLAYERS + 1];

float gF_TraceStartOrigin[MAXPLAYERS + 1][MAX_BUMPS][3];
float gF_TraceEndOrigin[MAXPLAYERS + 1][MAX_BUMPS][3];
float gF_TraceNormal[MAXPLAYERS + 1][MAX_BUMPS][3];

bool gB_PendingEdgebug[MAXPLAYERS + 1];
int gI_PendingEdgebugTick[MAXPLAYERS + 1];
float gF_PendingEdgebugOrigin[MAXPLAYERS + 1][3];
float gF_PendingEdgebugVelocity[MAXPLAYERS + 1][3];

int gI_LastEdgebugTick[MAXPLAYERS + 1];
int gI_LastPixelsurfTick[MAXPLAYERS + 1];
int gI_LastTexturebugTick[MAXPLAYERS + 1];

bool gB_BSPPeekReady;

void UpdateBSPPeekStatus()
{
	gB_BSPPeekReady = BSPPeek_Available() && (BSP_SelfTest() & 0x03) == 0x03;
}

void HookGameMovementFunctions()
{
	HookGameMovementFunction(H_OnDuck, "CCSGameMovement::Duck", DHooks_OnDuck_Pre, DHooks_OnDuck_Post);
	HookGameMovementFunction(H_OnLadderMove, "CGameMovement::LadderMove", DHooks_OnLadderMove_Pre, DHooks_OnLadderMove_Post);
	HookGameMovementFunction(H_OnFullLadderMove, "CGameMovement::FullLadderMove", DHooks_OnFullLadderMove_Pre, DHooks_OnFullLadderMove_Post);
	HookGameMovementFunction(H_OnAirAccelerate, "CGameMovement::AirAccelerate", DHooks_OnAirAccelerate_Pre, DHooks_OnAirAccelerate_Post);
	HookGameMovementFunction(H_OnWalkMove, "CGameMovement::WalkMove", DHooks_OnWalkMove_Pre, DHooks_OnWalkMove_Post);
	HookGameMovementFunction(H_OnJump, "CCSGameMovement::OnJump", DHooks_OnJump_Pre, DHooks_OnJump_Post);
	HookGameMovementFunction(H_OnPlayerMove, "CCSGameMovement::PlayerMove", DHooks_OnPlayerMove_Pre, DHooks_OnPlayerMove_Post);
	HookGameMovementFunction(H_OnCategorizePosition, "CGameMovement::CategorizePosition", DHooks_OnCategorizePosition_Pre, DHooks_OnCategorizePosition_Post);
	HookGameMovementFunction(H_OnTryPlayerMove, "CGameMovement::TryPlayerMove", DHooks_OnTryPlayerMove_Pre, DHooks_OnTryPlayerMove_Post);

	moveHelperAddr = GameConfGetAddress(gH_GameData, "sm_pSingleton");
	if (!moveHelperAddr)
	{
		SetFailState("Failed to find IMoveHelper::sm_pSingleton.");
	}

	// The instance is needed to hook, so this only resolves the setup here.
	H_OnTracePlayerBBox = DynamicHook.FromConf(gH_GameData, "CGameMovement::TracePlayerBBox");
	gB_TraceHookAvailable = H_OnTracePlayerBBox != null;
	if (!gB_TraceHookAvailable)
	{
		LogError("CGameMovement::TracePlayerBBox unavailable, using the MoveHelper touch list instead.");
	}
}

Action UpdateMoveData(Address pThis, int client, Function func)
{
	GameMove_GetOrigin(pThis, gF_Origin[client]);
	GameMove_GetVelocity(pThis, gF_Velocity[client]);
	Action result;
	Call_StartFunction(INVALID_HANDLE, func);
	Call_PushCell(client);
	Call_PushArrayEx(gF_Origin[client], 3, SM_PARAM_COPYBACK);
	Call_PushArrayEx(gF_Velocity[client], 3, SM_PARAM_COPYBACK);
	Call_Finish(result);
	if (result != Plugin_Continue)
	{
		GameMove_SetOrigin(pThis, gF_Origin[client]);
		GameMove_SetVelocity(pThis, gF_Velocity[client]);
	}
	return result;
}

public MRESReturn DHooks_OnDuck_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || Movement_GetMovetype(client) == MOVETYPE_NOCLIP)
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnDuckPre);
	
	gB_Ducking[client] = Movement_GetDucking(client);
	gB_ProcessingDuck[client] = true;

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnDuck_Post(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || Movement_GetMovetype(client) == MOVETYPE_NOCLIP)
	{
		return MRES_Ignored;
	}
	
	if (gB_Ducking[client] && !gB_OldDucking[client])
	{
		Call_OnStartDucking(client);
	}
	else if (!gB_Ducking[client] && gB_OldDucking[client])
	{
		Call_OnStopDucking(client);
	}
	gB_ProcessingDuck[client] = false;
	GameMove_GetOrigin(pThis, gF_PostDuckOrigin[client]);

	Action result = UpdateMoveData(pThis, client, Call_OnDuckPost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnLadderMove_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || Movement_GetMovetype(client) == MOVETYPE_NOCLIP)
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnLadderMovePre);

	gB_ProcessingLadderMove[client] = true;
	GameMove_GetVelocity(pThis, gF_PreLadderMoveVelocity[client]);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnLadderMove_Post(Address pThis, DHookReturn hReturn)
{
	// While the movetype changed here, the vertical velocity is not yet updated.
	// gF_PostLadderMoveVelocity can be incorrect here.
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || Movement_GetMovetype(client) == MOVETYPE_NOCLIP)
	{
		return MRES_Ignored;
	}
	
	GameMove_GetOrigin(pThis, gF_PostLadderMoveOrigin[client]);
	GameMove_GetVelocity(pThis, gF_PostLadderMoveVelocity[client]);
	gB_ProcessingLadderMove[client] = false;
	bool returnValue = DHookGetReturn(hReturn);
	// If this returns false, and the movetype was originally MOVETYPE_LADDER, that means the player will change movetype and takeoff (LAJ)
	// If this returns true, the movetype can still change in FullLadderMove by jumping (LAH)
	// The current movetype here is still ladder, but it will change right after this function call.
	if (!returnValue && Movement_GetMovetype(client) == MOVETYPE_LADDER)
	{
		gF_TakeoffVelocity[client] = gF_PostLadderMoveVelocity[client];
		gF_TakeoffOrigin[client] = gF_PostLadderMoveOrigin[client];
		gI_TakeoffTick[client] = gI_TickCount[client];
		gI_TakeoffCmdNum[client] = gI_Cmdnum[client];
		gB_Jumped[client] = false;
		gB_HitPerf[client] = false;
		// Engine refreshes m_vecLadderNormal every laddering tick before any dismount branch.
		GetEntPropVector(client, Prop_Send, "m_vecLadderNormal", gF_TakeoffLadderNormal[client]);
		Call_OnChangeMovetype(client, MOVETYPE_LADDER, MOVETYPE_WALK);
	}
	else if (returnValue && gMT_OldMovetype[client] != MOVETYPE_LADDER)
	{
		if (Movement_GetMovetype(client) == MOVETYPE_LADDER)
		{
			gF_LandingOrigin[client] = gF_PostLadderMoveOrigin[client];
			// We don't really care about nobug origin when player lands on ladder.
			gF_NobugLandingOrigin[client] = gF_LandingOrigin[client];
			gF_LandingVelocity[client] = gF_PreLadderMoveVelocity[client];
			gI_LandingCmdNum[client] = gI_Cmdnum[client];
			gI_LandingTick[client] = gI_TickCount[client];
			Call_OnChangeMovetype(client, MOVETYPE_WALK, MOVETYPE_LADDER);
		}
	}
	else if (returnValue && gMT_OldMovetype[client] == MOVETYPE_LADDER
		&& Movement_GetMovetype(client) == MOVETYPE_WALK)
	{
		// Jumping away from the ladder. The movetype switch is the engine's own verdict,
		// its LadderMove IN_JUMP branch already set movetype and velocity (ladderNormal * 270),
		// so no need to re-derive the button and m_ignoreLadderJumpTime condition here.
		gF_TakeoffVelocity[client] = gF_PostLadderMoveVelocity[client];
		gF_TakeoffOrigin[client] = gF_PostLadderMoveOrigin[client];
		gI_TakeoffTick[client] = gI_TickCount[client];
		gI_TakeoffCmdNum[client] = gI_Cmdnum[client];
		gB_Jumped[client] = false;
		gB_HitPerf[client] = false;
		gB_TakeoffFromLadder[client] = true;
		GetEntPropVector(client, Prop_Send, "m_vecLadderNormal", gF_TakeoffLadderNormal[client]);
		Call_OnChangeMovetype(client, MOVETYPE_LADDER, MOVETYPE_WALK);
	}
	Action result = UpdateMoveData(pThis, client, Call_OnLadderMovePost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnFullLadderMove_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnFullLadderMovePre);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnJump_Pre(Address pThis, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}

	gB_Jumped[client] = true;
	if (gB_Duckbugged[client])
	{
		gB_Jumpbugged[client] = true;
	}

	// HitPerf must be modified here so plugins can know if player hits a perf or not.
	// Not a perf if last movetype was ladder, because jumping works differently on ladders.
	if (gMT_OldMovetype[client] != MOVETYPE_LADDER) 
	{
		// If you walked on the last tick then clearly it's not going to be a perf.
		// Can't perf if you don't jump.
		gB_HitPerf[client] = !gB_OldWalkMoved[client];
	}
	else
	{
		gB_HitPerf[client] = false;
	}

	Action result = UpdateMoveData(pThis, client, Call_OnJumpPre);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnJump_Post(Address pThis, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	// We need to update LadderMove velocity again in case of jumping.
	GameMove_GetVelocity(pThis, gF_PostLadderMoveVelocity[client]);

	// Current origin because the player hasn't moved yet.
	gF_TakeoffOrigin[client] = gF_Origin[client];
	gF_TakeoffVelocity[client] = gF_Velocity[client];
	gI_TakeoffCmdNum[client] = gI_Cmdnum[client];
	gI_TakeoffTick[client] = gI_TickCount[client];
	if (!gB_TakeoffFromLadder[client])
	{
		gF_TakeoffLadderNormal[client] = view_as<float>( { 0.0, 0.0, 0.0 } );
	}

	// OnJump will only be called if the client previously touched some sort of ground, so Call_OnStopTouchGround should always be called.
	Call_OnStopTouchGround(client, true, gB_TakeoffFromLadder[client], gB_Jumpbugged[client]);

	Action result = UpdateMoveData(pThis, client, Call_OnJumpPost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnFullLadderMove_Post(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || Movement_GetMovetype(client) == MOVETYPE_NOCLIP)
	{
		return MRES_Ignored;
	}

	Action result = UpdateMoveData(pThis, client, Call_OnFullLadderMovePost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}
// We hook AirAccelerate because TryPlayerMove in AirMove can change velocity
// AirAccelerate velocity is required for nobug landing origin.
public MRESReturn DHooks_OnAirAccelerate_Pre(Address pThis, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnAirAcceleratePre);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnAirAccelerate_Post(Address pThis, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	
	GameMove_GetOrigin(pThis, gF_PostAAOrigin[client]);
	GameMove_GetVelocity(pThis, gF_PostAAVelocity[client]);

	Action result = UpdateMoveData(pThis, client, Call_OnAirAcceleratePost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

// WalkMove is called too early to detect if the player is still on ground or not.
public MRESReturn DHooks_OnWalkMove_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnWalkMovePre);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnWalkMove_Post(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}

	GameMove_GetVelocity(pThis, gF_PostWalkMoveVelocity[client]);
	gB_WalkMoved[client] = true;

	Action result = UpdateMoveData(pThis, client, Call_OnWalkMovePost);	
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnPlayerMove_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	
	gB_Duckbugged[client] = false;
	gB_WalkMoved[client] = false;
	gB_Jumpbugged[client] = false;
	gB_Jumped[client] = false;
	gB_TakeoffFromLadder[client] = false;
	gB_TryPlayerMoveThisTick[client] = false;
	gI_CollisionCount[client] = 0;
	gB_InTryPlayerMove[client] = false;
	gB_SeededFirstTrace[client] = false;

	Action result = UpdateMoveData(pThis, client, Call_OnPlayerMovePre);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnPlayerMove_Post(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnPlayerMovePost);
	gB_TryPlayerMoveThisTick[client] = false;
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnCategorizePosition_Pre(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnCategorizePositionPre);

	gB_PrevOnGround[client] = Movement_GetOnGround(client);

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnCategorizePosition_Post(Address pThis)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}
	bool ground = Movement_GetOnGround(client);

	if (gB_PendingEdgebug[client])
	{
		if (!ground && gI_PendingEdgebugTick[client] == GetGameTickCount()
			&& gI_LastEdgebugTick[client] != GetGameTickCount())
		{
			gI_LastEdgebugTick[client] = GetGameTickCount();
			Call_OnPlayerEdgebug(client, gF_PendingEdgebugOrigin[client], gF_PendingEdgebugVelocity[client]);
		}
		gB_PendingEdgebug[client] = false;
	}

	// Ground state changed!
	if (gB_PrevOnGround[client] != ground)
	{
		if (ground) // Landing
		{
			NobugLandingOrigin(client, gF_NobugLandingOrigin[client]);
			
			gF_LandingOrigin[client] = gF_Origin[client];
			gI_LandingCmdNum[client] = gI_Cmdnum[client];
			gI_LandingTick[client] = gI_TickCount[client];
			Call_OnStartTouchGround(client);
		}
		else // Takeoff
		{
			gF_TakeoffOrigin[client] = gF_OldOrigin[client];
			// Note: Jumping isn't detected here.
			if (gB_WalkMoved[client])
			{
				gF_TakeoffVelocity[client] = gF_PostWalkMoveVelocity[client];
			}
			else
			{
				gF_TakeoffVelocity[client] = gF_PostLadderMoveVelocity[client];
			}
			gI_TakeoffTick[client] = gI_TickCount[client];
			gI_TakeoffCmdNum[client] = gI_Cmdnum[client];
			gB_Jumped[client] = false;
			gB_HitPerf[client] = false;
			bool hadLadderMoveType = Movement_GetMovetype(client) == MOVETYPE_LADDER || gMT_OldMovetype[client] == MOVETYPE_LADDER;
			bool ladderJump = hadLadderMoveType && !gB_WalkMoved[client];
			if (ladderJump)
			{
				GetEntPropVector(client, Prop_Send, "m_vecLadderNormal", gF_TakeoffLadderNormal[client]);
			}
			else
			{
				gF_TakeoffLadderNormal[client] = view_as<float>( { 0.0, 0.0, 0.0 } );
			}
			Call_OnStopTouchGround(client, false, ladderJump, false);
		}
	}

	Action result = UpdateMoveData(pThis, client, Call_OnCategorizePositionPost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

public MRESReturn DHooks_OnTryPlayerMove_Pre(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (!IsPlayerAlive(client) || IsFakeClient(client))
	{
		return MRES_Ignored;
	}
	Action result = UpdateMoveData(pThis, client, Call_OnTryPlayerMovePre);

	for (int i = 0; i < MAX_BUMPS; i++)
	{
		gF_TraceStartOrigin[client][i] = NULL_VECTOR;
		gF_TraceEndOrigin[client][i] = NULL_VECTOR;
		gF_TraceNormal[client][i] = NULL_VECTOR;
		gF_TraceDist[client][i] = 0.0;
	}
	gI_CollisionCount[client] = 0;
	gB_InTryPlayerMove[client] = true;
	gB_SeededFirstTrace[client] = false;

	// CGameMovement is a singleton, so one raw hook covers every player.
	// HookRaw throws rather than returning on a bad setup, which aborts this callback,
	// so mark the attempt before calling it. Otherwise a throw retries every tick.
	if (gB_TraceHookAvailable && !gB_TraceHookAttempted)
	{
		gB_TraceHookAttempted = true;
		gB_TraceHookAvailable = false;
		gI_TraceHookId = H_OnTracePlayerBBox.HookRaw(Hook_Post, pThis, DHooks_OnTracePlayerBBox_Post);
		if (gI_TraceHookId == INVALID_HOOK_ID)
		{
			LogError("Failed to hook CGameMovement::TracePlayerBBox, using the MoveHelper touch list instead.");
		}
		else
		{
			gB_TraceHookAvailable = true;
		}
	}

	// Seed bump 0 from pFirstTrace so the reuse path isn't a blind spot.
	if (!DHookIsNullParam(hParams, 2))
	{
		float fraction = DHookGetParamObjectPtrVar(hParams, 2, TRACE_FRACTION, ObjectValueType_Float);
		bool allsolid = view_as<bool>(DHookGetParamObjectPtrVar(hParams, 2, TRACE_ALLSOLID, ObjectValueType_Bool));
		if (fraction < 1.0 && !allsolid)
		{
			DHookGetParamObjectPtrVarVector(hParams, 2, TRACE_STARTPOS, ObjectValueType_Vector, gF_TraceStartOrigin[client][0]);
			DHookGetParamObjectPtrVarVector(hParams, 2, TRACE_ENDPOS, ObjectValueType_Vector, gF_TraceEndOrigin[client][0]);
			DHookGetParamObjectPtrVarVector(hParams, 2, TRACE_NORMAL, ObjectValueType_Vector, gF_TraceNormal[client][0]);
			gF_TraceDist[client][0] = DHookGetParamObjectPtrVar(hParams, 2, TRACE_DIST, ObjectValueType_Float);
			gI_CollisionCount[client] = 1;
			gB_SeededFirstTrace[client] = true;
			DHookGetParamVector(hParams, 1, gF_SeedFirstDest[client]);
		}
	}

	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

static bool VectorsNearEqual(const float a[3], const float b[3])
{
	return FloatAbs(a[0] - b[0]) < 0.001 && FloatAbs(a[1] - b[1]) < 0.001 && FloatAbs(a[2] - b[2]) < 0.001;
}

// Records every blocking bump trace of the current TryPlayerMove call.
public MRESReturn DHooks_OnTracePlayerBBox_Post(Address pThis, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (client < 1 || !gB_InTryPlayerMove[client])
	{
		return MRES_Ignored;
	}

	float start[3], end[3];
	DHookGetParamVector(hParams, 1, start);
	DHookGetParamVector(hParams, 2, end);
	// TryPlayerMove also runs unswept stuck tests.
	if (VectorsNearEqual(start, end))
	{
		return MRES_Ignored;
	}

	float fraction = DHookGetParamObjectPtrVar(hParams, 5, TRACE_FRACTION, ObjectValueType_Float);
	bool allsolid = view_as<bool>(DHookGetParamObjectPtrVar(hParams, 5, TRACE_ALLSOLID, ObjectValueType_Bool));
	if (fraction >= 1.0 || allsolid)
	{
		return MRES_Ignored;
	}

	int idx = gI_CollisionCount[client];
	// The engine re-traces the seeded bump only when the destination's z differs,
	// so a first capture matching the seed's start and XY destination replaces it.
	if (gB_SeededFirstTrace[client] && idx == 1
		&& VectorsNearEqual(start, gF_TraceStartOrigin[client][0])
		&& FloatAbs(end[0] - gF_SeedFirstDest[client][0]) < 0.01
		&& FloatAbs(end[1] - gF_SeedFirstDest[client][1]) < 0.01)
	{
		idx = 0;
	}
	gB_SeededFirstTrace[client] = false;
	if (idx >= MAX_BUMPS)
	{
		return MRES_Ignored;
	}

	DHookGetParamObjectPtrVarVector(hParams, 5, TRACE_STARTPOS, ObjectValueType_Vector, gF_TraceStartOrigin[client][idx]);
	DHookGetParamObjectPtrVarVector(hParams, 5, TRACE_ENDPOS, ObjectValueType_Vector, gF_TraceEndOrigin[client][idx]);
	DHookGetParamObjectPtrVarVector(hParams, 5, TRACE_NORMAL, ObjectValueType_Vector, gF_TraceNormal[client][idx]);
	gF_TraceDist[client][idx] = DHookGetParamObjectPtrVar(hParams, 5, TRACE_DIST, ObjectValueType_Float);
	if (idx == gI_CollisionCount[client])
	{
		gI_CollisionCount[client] = idx + 1;
	}
	return MRES_Ignored;
}

// IMoveHelper's touch list, reset once per RunCommand.
// Dedupes by entity and the world is one entity, so a tick that clips a wall then a floor only reports the wall.
static void ReadTouchListCollisions(int client)
{
	int touchCount = LoadFromAddress(moveHelperAddr + view_as<Address>(8) + view_as<Address>(12), NumberType_Int32);
	if (touchCount > MAX_BUMPS)
	{
		// A CUtlVector with no fixed cap. Clamp before indexing.
		touchCount = MAX_BUMPS;
	}
	else if (touchCount < 0)
	{
		touchCount = 0;
	}
	if (touchCount == 0)
	{
		return;
	}

	Address elements = LoadFromAddress(moveHelperAddr + view_as<Address>(8) + view_as<Address>(16), NumberType_Int32);
	for (int i = 0; i < touchCount; i++)
	{
		Trace trace = Trace(elements + view_as<Address>(i * 96) + view_as<Address>(12));
		trace.startpos.ToArray(gF_TraceStartOrigin[client][i]);
		trace.endpos.ToArray(gF_TraceEndOrigin[client][i]);
		trace.plane.normal.ToArray(gF_TraceNormal[client][i]);
		gF_TraceDist[client][i] = trace.plane.dist;
	}
	gI_CollisionCount[client] = touchCount;
}

public MRESReturn DHooks_OnTryPlayerMove_Post(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	int client = GetClientFromGameMovementAddress(pThis);
	if (client >= 1)
	{
		gB_InTryPlayerMove[client] = false;
		gB_SeededFirstTrace[client] = false;
	}
	if (!IsPlayerAlive(client) || IsFakeClient(client))
	{
		return MRES_Ignored;
	}

	gB_TryPlayerMoveThisTick[client] = true;

	// Nothing captured means the hook is absent, or its calls were inlined away.
	// The touch list is the pre-hook source: entity-deduped, so repeated world contacts
	// collapse into one, but it is always populated.
	if (gI_CollisionCount[client] == 0)
	{
		ReadTouchListCollisions(client);
	}

	// bestNormalZ drives detection and may be disp-refined.
	// PxSeamVerdict gets the raw plane values, since plane dist is only a world height for a truly axial plane.
	float bestNormalZ = 0.0;
	float bestRawNormalZ = 0.0;
	float seamZ = 0.0;
	for (int i = 0; i < gI_CollisionCount[client]; i++)
	{
		float rawNormalZ = gF_TraceNormal[client][i][2];
		float normalZ = rawNormalZ;
		// Hull normals are coarse at displacement seams. Check the mesh's true tri normal.
		if (gB_BSPPeekReady && rawNormalZ >= STANDABLE_NORMAL_Z && rawNormalZ < PX_TOP_NORMAL_Z)
		{
			normalZ = RefineDispNormalZ(gF_TraceEndOrigin[client][i], rawNormalZ);
		}
		if (normalZ > bestNormalZ)
		{
			bestNormalZ = normalZ;
			bestRawNormalZ = rawNormalZ;
			seamZ = gF_TraceDist[client][i];
		}
	}

	// An edgebug requires the player to start the tick airborne.
	// Walking on ground keeps FL_ONGROUND set, so it never qualifies.
	bool startedAirborne = (GetEntityFlags(client) & FL_ONGROUND) == 0;

	// Edgebug / pixelsurf detection.
	// PX_TOP_NORMAL_Z is deliberately far stricter than the engine's 0.7 standable cutoff:
	// an edgebug is a flat-floor clip that zeroes vertical velocity mid-tick, so a plain slope contact must not qualify.
	if (bestNormalZ >= PX_TOP_NORMAL_Z)
	{
		float currentOrigin[3], groundEndPoint[3];

		GameMove_GetOrigin(pThis, currentOrigin);
		float mins[3] = {-16.0, -16.0, 0.0};
		float maxs[3] = {16.0, 16.0, 0.0};

		groundEndPoint = currentOrigin;
		groundEndPoint[2] -= 2.0;
		TR_TraceHullFilter(currentOrigin, groundEndPoint, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers, client);
		bool noGroundUnderfoot = !TR_DidHit();

		// Pixelsurf takes priority over an edgebug this tick.
		bool pixelsurfed = false;
		if (noGroundUnderfoot)
		{
			// 1 surfable, 0 dead seam, -1 unresolved. Only -1 falls back to the ray probes.
			int bspVerdict = -1;
			if (gB_BSPPeekReady)
			{
				bspVerdict = PxSeamVerdict(currentOrigin, seamZ, bestRawNormalZ);
			}
			bool onSeam;
			if (bspVerdict >= 0)
			{
				onSeam = bspVerdict == 1;
			}
			else
			{
				float wallPos[3], wallNorm[3];
				onSeam = GetPressedWall(client, currentOrigin, wallPos, wallNorm)
					&& !FloorProtrudesFromWall(client, wallPos, wallNorm, currentOrigin[2]);
			}
			if (onSeam)
			{
				pixelsurfed = true;
				if (gI_LastPixelsurfTick[client] != GetGameTickCount())
				{
					gI_LastPixelsurfTick[client] = GetGameTickCount();
					Call_OnPlayerPixelsurf(client, gF_Origin[client], gF_Velocity[client]);
				}
			}
		}

		// Reports the same flat topside plane, but from near the brush's bottom.
		// Without bsppeek these ticks fall through to the edgebug path.
		bool texturebugged = false;
		if (!pixelsurfed && gB_BSPPeekReady)
		{
			texturebugged = CheckTexturebug(client, gF_Origin[client], seamZ);
		}

		if (startedAirborne && !pixelsurfed && !texturebugged)
		{
			gB_PendingEdgebug[client] = true;
			gI_PendingEdgebugTick[client] = GetGameTickCount();
			gF_PendingEdgebugOrigin[client] = gF_Origin[client];
			gF_PendingEdgebugVelocity[client] = gF_Velocity[client];
		}
	}

	Action result = UpdateMoveData(pThis, client, Call_OnTryPlayerMovePost);
	if (result != Plugin_Continue)
	{
		return MRES_Handled;
	}
	else
	{
		return MRES_Ignored;
	}
}

// Pixelsurf 1/2: is the player pressed flush against a wall, and if so which one?
static bool GetPressedWall(int client, const float origin[3], float wallPos[3], float wallNorm[3])
{
	float heights[2];
	heights[0] = 18.0;
	heights[1] = 40.0;

	for (int h = 0; h < sizeof(heights); h++)
	{
		float start[3];
		start = origin;
		start[2] += heights[h];

		for (int d = 0; d < PX_WALL_DIRS; d++)
		{
			float yaw = DegToRad(d * (360.0 / PX_WALL_DIRS));
			float dir[3];
			dir[0] = Cosine(yaw);
			dir[1] = Sine(yaw);

			float end[3];
			end[0] = start[0] + dir[0] * PX_WALL_PROBE_DIST;
			end[1] = start[1] + dir[1] * PX_WALL_PROBE_DIST;
			end[2] = start[2];

			TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers, client);
			if (!TR_DidHit())
			{
				continue;
			}

			float normal[3];
			TR_GetPlaneNormal(null, normal);
			if (FloatAbs(normal[2]) >= PX_WALL_NORMAL_Z)
			{
				continue;
			}

			float hitPos[3];
			TR_GetEndPosition(hitPos);
			float perp = FloatAbs((start[0] - hitPos[0]) * normal[0] + (start[1] - hitPos[1]) * normal[1]);
			float support = PX_WALL_HALF_WIDTH * (FloatAbs(normal[0]) + FloatAbs(normal[1]));
			if (perp <= support + PX_WALL_PRESS_MARGIN)
			{
				wallPos = hitPos;
				wallNorm = normal;
				return true;
			}
		}
	}
	return false;
}

// Pixelsurf 2/2: does a real, walkable floor protrude from the wall at the catch height?
static bool FloorProtrudesFromWall(int client, const float wallPos[3], const float wallNorm[3], float catchZ)
{
	float outs[2];
	outs[0] = 4.0;
	outs[1] = 8.0;

	for (int i = 0; i < sizeof(outs); i++)
	{
		float start[3];
		start[0] = wallPos[0] + wallNorm[0] * outs[i];
		start[1] = wallPos[1] + wallNorm[1] * outs[i];
		start[2] = catchZ + PX_FLOOR_PROBE_DROP;

		float end[3];
		end[0] = start[0];
		end[1] = start[1];
		end[2] = catchZ - PX_FLOOR_PROBE_DROP;

		TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers, client);
		if (!TR_DidHit())
		{
			continue;
		}

		float normal[3];
		TR_GetPlaneNormal(null, normal);
		if (normal[2] < PX_TOP_NORMAL_Z)
		{
			continue;
		}

		float hitPos[3];
		TR_GetEndPosition(hitPos);
		if (FloatAbs(hitPos[2] - catchZ) <= PX_FLOOR_PROBE_TOL)
		{
			return true;
		}
	}
	return false;
}

// True tri normal z of the disp collision mesh at a contact, rawNormalZ if no disp there.
// XY surface query first (picks the tread, not a seam riser), nearest-tri as fallback.
static float RefineDispNormalZ(const float contactPos[3], float rawNormalZ)
{
	float normal[3];
	float surfZ = BSP_DispSurfaceNormalAt(contactPos[0], contactPos[1], normal);
	if (surfZ > BSP_DISP_NO_HIT && FloatAbs(surfZ - contactPos[2]) <= 4.0)
	{
		return normal[2];
	}
	float v0[3], v1[3], v2[3];
	if (BSP_DispNearestTri(contactPos, 4.0, normal, v0, v1, v2) > BSP_DISP_NO_HIT)
	{
		return normal[2];
	}
	return rawNormalZ;
}

// Gate logic ported from fkz-routecalc pixelsurf/bsp.sp.
// Wall direction is unknown here, so every cardinal column around the hull is tried.
// Returns 1 surfable, 0 dead seam, -1 unresolved.
static int PxSeamVerdict(const float origin[3], float seamZ, float contactNormalZ)
{
	// plane.dist is only a world height on a truly axial plane.
	// A tilted 0.999 contact (displacement) makes seamZ meaningless.
	if (contactNormalZ < 0.9999)
	{
		return -1;
	}

	// The engine stops the player DIST_EPSILON short of the clipped plane.
	// Also rules out texturebugs, which report the same plane from far below its top.
	float heightAboveSeam = origin[2] - seamZ;
	if (heightAboveSeam < -0.001 || heightAboveSeam > BSP_DIST_EPSILON + 0.001)
	{
		return 0;
	}

	// The seam finders match brushes whose XY footprint contains the probe,
	// so probe just past the hull face to land inside the wall column.
	bool anyDead = false;
	float probe[3];
	for (int d = 0; d < 4; d++)
	{
		probe = origin;
		switch (d)
		{
			case 0: probe[0] += PX_WALL_HALF_WIDTH + 1.0;
			case 1: probe[0] -= PX_WALL_HALF_WIDTH + 1.0;
			case 2: probe[1] += PX_WALL_HALF_WIDTH + 1.0;
			case 3: probe[1] -= PX_WALL_HALF_WIDTH + 1.0;
		}
		probe[2] = seamZ;

		int verdict = PxSeamVerdictAt(probe, seamZ);
		if (verdict == 1)
		{
			return 1;
		}
		if (verdict == 0)
		{
			anyDead = true;
		}
	}
	return anyDead ? 0 : -1;
}

// One wall column. Rejects need a confirmed-bad signal, anything unclear is -1.
static int PxSeamVerdictAt(const float samplePos[3], float seamZ)
{
	// CSGO box-optimized walls live in the cboxbrush table, invisible to the cbrush finder below.
	int lowerBox, upperBox;
	if (BSP_FindBoxBrushPairAtSeam(samplePos, seamZ, lowerBox, upperBox))
	{
		int lowerContents = BSP_BoxBrushContents(lowerBox);
		int upperContents = BSP_BoxBrushContents(upperBox);
		if ((lowerContents & BSPP_MASK_PLAYERCOLLIDE) == 0
			|| (upperContents & BSPP_MASK_PLAYERCOLLIDE) == 0)
		{
			return 0;
		}
		// The lower box's top only wins the fraction-0 stalemate if tested first.
		// Clip pairs surf regardless of order.
		int clipMask = BSPP_CONTENTS_PLAYERCLIP | BSPP_CONTENTS_MONSTERCLIP;
		if ((lowerContents & clipMask) == 0 && (upperContents & clipMask) == 0
			&& !BoxPairOrderOK(samplePos, seamZ, lowerBox, upperBox))
		{
			return 0;
		}
		return 1;
	}

	// Only true when both brushes share the seam leaf and the lower is listed first.
	int lower, upper, leaf, lowerPos, upperPos;
	if (BSP_LeafBrushPairAtSeam(samplePos, seamZ, lower, upper, leaf, lowerPos, upperPos))
	{
		if ((BSP_BrushContents(lower) & BSPP_MASK_PLAYERCOLLIDE) == 0)
		{
			return 0;
		}
		return 1;
	}

	// Gate failed, but it fills every out-param anyway, so reject on the confirmed-bad signals.
	// Unresolved cases stay -1: brush-entity walls, leaf-boundary flush pairs, displacements.
	if (lower >= 0 && upper >= 0)
	{
		if ((BSP_BrushContents(lower) & BSPP_MASK_PLAYERCOLLIDE) == 0)
		{
			return 0;
		}
		if (leaf >= 0 && lowerPos >= 0 && upperPos >= 0 && lowerPos >= upperPos)
		{
			return 0;
		}
	}
	return -1;
}

// Visit order is the leaf brush LIST position.
// The box-TABLE index is a vbsp slot, comparing those false-rejects real surfs.
// A box-optimized cbrush has rawNumSides 0xFFFF and firstSide repurposed as its box index.
// Only a confirmed out-of-order pair returns false.
static bool BoxPairOrderOK(const float samplePos[3], float seamZ, int lowerBox, int upperBox)
{
	float leafSample[3];
	leafSample = samplePos;
	leafSample[2] = seamZ - 0.5;
	int leaf = BSP_LeafAtPoint(leafSample);
	if (leaf < 0)
	{
		return true;
	}

	int brushes[128];
	int count = BSP_LeafBrushes(leaf, brushes, sizeof(brushes));
	int lowerPos = -1;
	int upperPos = -1;
	for (int i = 0; i < count; i++)
	{
		int rawNumSides, rawFirstSide, rawContents;
		BSP_BrushRaw(brushes[i], rawNumSides, rawFirstSide, rawContents);
		if (rawNumSides != 0xFFFF)
		{
			continue;
		}
		if (rawFirstSide == lowerBox && lowerPos < 0)
		{
			lowerPos = i;
		}
		if (rawFirstSide == upperBox && upperPos < 0)
		{
			upperPos = i;
		}
	}
	return !(lowerPos >= 0 && upperPos >= 0 && lowerPos > upperPos);
}

// Falling past an overhanging box brush while hugging its wall makes the engine report the brush's topside,
// because cmodel.cpp picks the checked z side from travel direction rather than the side actually crossed.
// The overhang finder needs a probe INSIDE the wall's XY column near the crossed edge,
// which is at HULL TOP height beside a hugging player, so try each cardinal column there.
// The Ineq 10 window is computed here on the probe's axis, since the native measures vPerp
// on whichever exposed face it picked, which can be the wrong axis on a corner box.
static bool CheckTexturebug(int client, const float origin[3], float seamZ)
{
	float velZ = gF_Velocity[client][2];
	if (velZ >= 0.0)
	{
		return false;
	}
	float hullHeight = gB_Ducking[client] ? BSP_CSGO_HULL_DUCK : BSP_CSGO_HULL_STAND;

	float probe[3];
	for (int d = 0; d < 4; d++)
	{
		probe = origin;
		probe[2] += hullHeight;
		int axis = d / 2;
		probe[axis] += (d & 1) ? -(PX_WALL_HALF_WIDTH + 1.0) : (PX_WALL_HALF_WIDTH + 1.0);

		int boxIdx, face;
		float wallCoord, bottomZ, height;
		if (!BSP_FindBoxBrushOverhang(probe, boxIdx, face, wallCoord, bottomZ, height))
		{
			continue;
		}
		// The misreported plane must be this box's own top, else the contact came from elsewhere.
		if (FloatAbs(bottomZ + height - seamZ) > 0.1)
		{
			continue;
		}
		float vPerp = FloatAbs(gF_Velocity[client][axis]);
		float maxVPerp = -velZ * BSP_DIST_EPSILON / (height + hullHeight);
		if (vPerp >= maxVPerp)
		{
			continue;
		}
		if (gI_LastTexturebugTick[client] != GetGameTickCount())
		{
			gI_LastTexturebugTick[client] = GetGameTickCount();
			Call_OnPlayerTexturebug(client, gF_Origin[client], gF_Velocity[client]);
		}
		return true;
	}
	return false;
}

// CategorizePosition's grounding trace: full hull 2u down, standable planes only.
// A steep hit retries the corner sub-boxes (TracePlayerBBoxForGround),
// but groundPos stays the main trace endpos, which is the engine's overwriteEndpos behavior.
static bool TraceGroundParity(int client, const float origin[3], float groundPos[3])
{
	float hullMins[3], hullMaxs[3];
	GetClientMins(client, hullMins);
	GetClientMaxs(client, hullMaxs);

	float endPoint[3];
	endPoint = origin;
	endPoint[2] -= 2.0;

	TR_TraceHullFilter(origin, endPoint, hullMins, hullMaxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers, client);
	if (!TR_DidHit())
	{
		return false;
	}
	TR_GetEndPosition(groundPos);

	float normal[3];
	TR_GetPlaneNormal(null, normal);
	if (normal[2] >= STANDABLE_NORMAL_Z)
	{
		return true;
	}

	// Engine quadrant order. It clamps the far half to 0, which for a player hull IS 0.
	for (int q = 0; q < 4; q++)
	{
		float mins[3], maxs[3];
		mins = hullMins;
		maxs = hullMaxs;
		switch (q)
		{
			case 0: { maxs[0] = 0.0; maxs[1] = 0.0; }
			case 1: { mins[0] = 0.0; mins[1] = 0.0; }
			case 2: { mins[1] = 0.0; maxs[0] = 0.0; }
			case 3: { mins[0] = 0.0; maxs[1] = 0.0; }
		}

		TR_TraceHullFilter(origin, endPoint, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers, client);
		if (!TR_DidHit())
		{
			continue;
		}
		TR_GetPlaneNormal(null, normal);
		if (normal[2] >= STANDABLE_NORMAL_Z)
		{
			return true;
		}
	}
	return false;
}

static void NobugLandingOrigin(int client, float landingOrigin[3])
{
	float groundEndPoint[3];
	groundEndPoint = gF_Origin[client];
	groundEndPoint[2] -= 2.0;

	float groundPos[3];
	if (!TraceGroundParity(client, gF_Origin[client], groundPos))
	{
		// Use groundEndPoint, this MIGHT give less distance in this rare case.
		groundPos = groundEndPoint;
	}

	gB_Duckbugged[client] = gB_ProcessingDuck[client];
	float distanceToGround = gF_Origin[client][2] - groundPos[2];
	float velocity[3], origin[3];
	// If there's any distance to the ground, then we'll trace it with this one.
	
	// It seems like sometimes the player can end up ever so slighly above this "ground" value,
	// likely due to floating point precision error. Treat it as a bugged jump as well.
	if (distanceToGround > 0.001 || gB_ProcessingDuck[client])
	{
		// Use the current origin and velocity if we're not touching the ground
		gF_LandingVelocity[client] = gF_Velocity[client];
		velocity = gF_Velocity[client];
		origin = gF_Origin[client];
	}
	else
	{
		// NOTE: Use gF_OldVelocity and gF_OldOrigin if jump is potentially bugged.
		gF_LandingVelocity[client] = gF_PostAAVelocity[client];
		velocity = gF_PostAAVelocity[client];
		origin = gF_PostAAOrigin[client];
	}

	// Jump is bugged, try to use the trace result of TryPlayerMove if possible.
	if (gB_TryPlayerMoveThisTick[client] && gI_CollisionCount[client] > 0)
	{
		landingOrigin = gF_TraceEndOrigin[client][0];
		return;
	}

	// The engine never grounds a player rising this fast, so nothing to extrapolate.
	if (velocity[2] > NON_JUMP_VELOCITY)
	{
		landingOrigin = groundPos;
		return;
	}

	// Fallback when no collision happened during TryPlayerMove, or that function was not called.
	float firstTraceEndpoint[3], scaledVelocity[3];
	scaledVelocity = velocity;
	ScaleVector(scaledVelocity, GetTickInterval());
	AddVectors(origin, scaledVelocity, firstTraceEndpoint);

	// Foot-level plate, not the full hull.
	float mins[3] = {-16.0, -16.0, 0.0};
	float maxs[3] = {16.0, 16.0, 0.0};
	TR_TraceHullFilter(origin, firstTraceEndpoint, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers, client);
	if (!TR_DidHit())
	{
		// It is possible to not hit the trace, if your vertical velocity is low enough.
		// In an extreme case, you would need 10 more traces for this to hit.
		// It is also possible to miss the trace on a flat jump, by hitting the very edge of a block.
		
		// Use groundPos, because this will give no distance advantage to the player, but
		// it will let the player not have his jump invalidated.
		landingOrigin = groundPos;
	}
	else
	{
		TR_GetEndPosition(landingOrigin);
	}
}
