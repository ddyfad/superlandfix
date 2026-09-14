#include <sdktools>
#include <sdkhooks>
#include <shavit/core>
#include <shavit/replay-recorder>
#include <shavit/replay-playback>
#include <clientprefs>
#include <dhooks>

#pragma semicolon 1

// Plugin Info -------------------------------------------------------

public Plugin myinfo = 
{
	name = "SuperLandfix",
	author = "olivia, Haze, nimmy, shinoum, lukah, nora, zas, daf",
	description = "Landfix (NoTimeLoss/Haze) with HUD, cookies, per jump toggles, tracked per run for spectators.",
	version = "1.0.0",
	url = "https://github.com/ddyfad/superlandfix"
}

// Global Variables --------------------------------------------------

char gS_Warning[16];

#define C_GREEN "\x0700FF00"
#define C_RED   "\x07FF0000"
#define C_PINK  "\x07DA96BF"	// the pink shavit uses for "ok" in the prefix
char gS_Style[16];

bool gB_Enabled[MAXPLAYERS+1] = {true, ...};
bool gB_LandfixType[MAXPLAYERS + 1] = {false, ...}; // false = NoTimeLoss | true = Haze
bool gB_UseHud[MAXPLAYERS+1] = {true, ...};
bool gB_PreferencesLoaded[MAXPLAYERS + 1];
int gI_PreferencesDirty[MAXPLAYERS + 1];

#define PREF_ENABLED  (1 << 0)
#define PREF_TYPE     (1 << 1)
#define PREF_HUD      (1 << 2)
#define PREF_POSITION (1 << 3)
#define PREF_COLOR    (1 << 4)
#define LANDFIX_HANDOFF_FILE "data/landfix-settings-handoff.kv"
bool gB_EditorHudHidden[MAXPLAYERS + 1];
bool gB_EditorHudPrevious[MAXPLAYERS + 1];
// A map starts before every client has finished loading it. HUD timers must
// be recreated after each player's first spawn, not from OnMapStart.
int gI_HudMapGeneration;
int gI_HudRestoredGeneration[MAXPLAYERS + 1];

int gI_LastGroundEntity[MAXPLAYERS + 1];
int gI_HudPositionPreset[MAXPLAYERS + 1];
int gI_HudColor[MAXPLAYERS + 1];

float gF_HudPositionX[MAXPLAYERS + 1];
float gF_HudPositionY[MAXPLAYERS + 1];
float gF_HudTimerDuration = 0.7;
// The hold time passed to SetHudTextParams used to equal gF_HudTimerDuration
// exactly, so the text's hold time expired at (almost) the same instant the
// repeating timer fired to redraw it. Any timer/frame jitter meant the text
// disappeared for a frame before the redraw landed, which read as a flash.
// Holding it well past the refresh interval guarantees the old text is still
// showing when the refresh arrives, so it never has a chance to blank out.
#define LANDFIX_HUD_HOLD_BUFFER 1.5

// HUD sync handle - owns a dedicated per-client channel independent of the
// 6-channel game_text pool used by DynamicChannels / jumpstats / shavit-hud.
Handle gH_HudSync;

Handle gH_hudTimers[MAXPLAYERS + 1] = { null, ... };
Handle gH_HudReconnectTimers[MAXPLAYERS + 1] = { null, ... };
int gI_HudReconnectUserId[MAXPLAYERS + 1];
int gI_HudReconnectAttempts[MAXPLAYERS + 1];

Handle gH_CheckJumpButtonHookPre;

// Version 2 stores all user-facing Landfix settings together. One write
// prevents a reconnect from restoring a mixture of old and new values.
Cookie gC_SettingsCookie;

// Version 2 is the main record. Keep the original cookies in sync as a
// recovery copy for players who have a damaged or missing version 2 record.
Cookie gC_LegacyEnabledCookie;
Cookie gC_LegacyLandfixTypeCookie;
Cookie gC_LegacyUseHudCookie;
Cookie gC_LegacyHudPositionCookie;
Cookie gC_LegacyHudColorCookie;

// HUD Colors
int gI_ColorRGB[6][4] = {
	{255,255,255,255},	// 0: White (Default)
	{0,255,255,255},	// 1: Cyan
	{255,0,255,255},	// 2: Purple
	{255,255,0,255},	// 3: Yellow
	{0,255,0,255},		// 4: Green
	{255,0,0,255}		// 5: Red
};

#define TOGGLE_COOLDOWN_TICKS 5		// stops one trigger firing twice and cancelling itself
#define LAND_GRACE_TICKS 3			// ramp and stair chatter right after takeoff is not a landing


enum struct Target
{
	int kind;	// 0 = single jump, 1 = range
	int start;
	int end;	// only used when kind is 1
}

ArrayList gA_LandfixTargets[MAXPLAYERS+1];

bool gB_LandfixJumpsEnabled[MAXPLAYERS+1];
bool gB_LandfixWindowActive[MAXPLAYERS+1];
bool gB_LandfixBaseState[MAXPLAYERS+1];
bool gB_LandfixRangeActive[MAXPLAYERS+1];

int gI_LandfixRangeEndJump[MAXPLAYERS+1];
int gI_LandfixOneShotEndJump[MAXPLAYERS+1];
int gI_LandfixLastToggleTick[MAXPLAYERS+1];

// Per-map jump toggles, kept in SQL instead of a cookie so they can be browsed for other players too.
Database gH_LandfixDB;
ConVar gCV_LandfixDatabase;
bool gB_LandfixDBReady;
int gI_LandfixLoadGen[MAXPLAYERS + 1];
char gS_LandfixMap[PLATFORM_MAX_PATH];

bool gB_WasOnGround[MAXPLAYERS + 1];
int gI_LastTakeoffTick[MAXPLAYERS + 1];
int gI_LastJumps[MAXPLAYERS + 1];

ConVar gCV_ToggleHints;

// Where a correction actually moved the player, kept for the length of a run.
// A replay stores position and nothing else, so the file cannot say whether
// landfix caught a landing or the player simply hit it clean.

#define LANDFIX_MARK_VERSION 2
#define LANDFIX_MARK_MAX 1024		// a run trips a handful; this only catches a runaway
#define LANDFIX_MARK_EPSILON 0.01	// Haze runs on every ground change, most of which move nothing
#define LANDFIX_TIME_EPSILON 0.0016	// replay-history truncates the run time it puts in a filename

ArrayList gA_LandfixMarks[MAXPLAYERS+1];	// blocks of {float time, int jump, int mode}
bool gB_LandfixMarksFull[MAXPLAYERS+1];

// Every time landfix went on or off during the run, starting with what it was set to
// when the timer did. Corrections alone cannot answer this: a stretch with no marks
// looks the same whether landfix was off or simply never needed.
ArrayList gA_LandfixStates[MAXPLAYERS+1];	// blocks of {float time, int enabled, int mode}

// Copied at Shavit_OnFinish. The live arrays above are often already gone by
// the time the replay is written.
ArrayList gA_FinishedMarks[MAXPLAYERS+1];
ArrayList gA_FinishedStates[MAXPLAYERS+1];
bool gB_FinishedTruncated[MAXPLAYERS+1];
bool gB_FinishedEnabled[MAXPLAYERS+1];
bool gB_FinishedMode[MAXPLAYERS+1];
bool gB_HaveFinished[MAXPLAYERS+1];

// Whether shavit-replay-playback is loaded. Everything that reads a replay is
// skipped when it is not.
bool g_bReplayPlayback;

// The same, for the replay a bot is playing, so a spectator reads the run's landfix
// instead of their own. Indexed by bot entity, which is a fake client.
ArrayList gA_BotStates[MAXPLAYERS+1];
bool gB_BotMarksKnown[MAXPLAYERS+1];		// a replay has been looked up for this bot
bool gB_BotMarksTracked[MAXPLAYERS+1];		// and it had a marks file beside it
bool gB_BotMarksEnabled[MAXPLAYERS+1];
int gI_BotMarksMode[MAXPLAYERS+1];

// Plugin Start ------------------------------------------------------

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// Replay playback is optional. Without it the marks, the spectator HUD and
	// /lfc are unavailable, and everything else works as normal.
	MarkNativeAsOptional("Shavit_IsReplayEntity");
	MarkNativeAsOptional("Shavit_GetReplayBotCache");
	MarkNativeAsOptional("Shavit_GetReplayBotStyle");
	MarkNativeAsOptional("Shavit_GetReplayBotTrack");
	MarkNativeAsOptional("Shavit_GetReplayBotCurrentFrame");
	MarkNativeAsOptional("Shavit_GetReplayCachePreFrames");
	MarkNativeAsOptional("Shavit_GetReplayFolderPath");

	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	g_bReplayPlayback = LibraryExists("shavit-replay-playback");
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
		g_bReplayPlayback = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
		g_bReplayPlayback = false;
}

public void OnPluginStart()
{
	gH_HudSync = CreateHudSynchronizer();

	// Commands -----
	
	// Toggle Landfix
	RegConsoleCmd("sm_lf", Command_LandFix, "Landfix");
	RegConsoleCmd("sm_landfix", Command_LandFix, "Landfix");
	RegConsoleCmd("sm_lfix", Command_LandFix, "Landfix");
	RegConsoleCmd("sm_land", Command_LandFix, "Landfix");
	RegConsoleCmd("sm_64", Command_LandFix, "Landfix");
	RegConsoleCmd("sm_64fix", Command_LandFix, "Landfix");

	// Toggle Landfix Type
	RegConsoleCmd("sm_lfs", Command_LandFixType, "LandfixType");
	RegConsoleCmd("sm_lftype", Command_LandFixType, "LandfixType");
	RegConsoleCmd("sm_landfixtype", Command_LandFixType, "LandfixType");
	RegConsoleCmd("sm_64type", Command_LandFixType, "LandfixType");
	RegConsoleCmd("sm_64t", Command_LandFixType, "LandfixType");
	
	// Toggle Landfix HUD
	RegConsoleCmd("sm_lfh", Command_LandFixHud, "LandfixHud");
	RegConsoleCmd("sm_lfhud", Command_LandFixHud, "LandfixHud");
	RegConsoleCmd("sm_landfixhud", Command_LandFixHud, "LandfixHud");
	RegConsoleCmd("sm_landhud", Command_LandFixHud, "LandfixHud");
	RegConsoleCmd("sm_lhud", Command_LandFixHud, "LandfixHud");
	RegConsoleCmd("sm_64hud", Command_LandFixHud, "LandfixHud");
	
	// Change HUD Position

	// Change HUD Color
	RegConsoleCmd("sm_lfhc", Command_LandFixHudColor, "LandfixHUDColor");
	RegConsoleCmd("sm_lfcolor", Command_LandFixHudColor, "LandfixHUDColor");
	RegConsoleCmd("sm_lfhudcolor", Command_LandFixHudColor, "LandfixHUDColor");
	RegConsoleCmd("sm_64hudcolor", Command_LandFixHudColor, "LandfixHUDColor");
	RegConsoleCmd("sm_64color", Command_LandFixHudColor, "LandfixHUDColor");
	RegConsoleCmd("sm_64c", Command_LandFixHudColor, "LandfixHUDColor");
	
	// Landfix Main Menu
	RegConsoleCmd("sm_lfm", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_lfmenu", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_landmenu", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_landfixmenu", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_landfixsettings", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_lfsettings", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_lfoptions", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_landfixconfig", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_lfconfig", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_64menu", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_64m", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_64settings", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_64options", Command_LandFixMenu, "LandfixMenu");
	RegConsoleCmd("sm_64config", Command_LandFixMenu, "LandfixMenu");

	// Landfix Commands Menu
	RegConsoleCmd("sm_lfi", Command_LandFixCommandsMenu, "LandfixCommandsMenu");
	RegConsoleCmd("sm_lfcmds", Command_LandFixCommandsMenu, "LandfixCommandsMenu");
	RegConsoleCmd("sm_lfcommands", Command_LandFixCommandsMenu, "LandfixCommandsMenu");
	RegConsoleCmd("sm_landfixcommands", Command_LandFixCommandsMenu, "LandfixCommandsMenu");

	// Landfix About Menu
	RegConsoleCmd("sm_lfa", Command_LandFixAboutMenu, "LandfixAboutMenu");
	RegConsoleCmd("sm_lfabout", Command_LandFixAboutMenu, "LandfixAboutMenu");
	RegConsoleCmd("sm_64about", Command_LandFixAboutMenu, "LandfixAboutMenu");
	RegConsoleCmd("sm_landfixabout", Command_LandFixAboutMenu, "LandfixAboutMenu");

	// Jump Toggles -----

	RegConsoleCmd("sm_lft", Command_LandfixJumps, "Landfix Toggler menu, or add landfix jumps: !lft 5 7 10-12");

	RegConsoleCmd("sm_lfc", Command_LandfixCheck, "What landfix the replay being spectated was run with");
	RegConsoleCmd("sm_lfcheck", Command_LandfixCheck, "What landfix the replay being spectated was run with");
	RegConsoleCmd("sm_checklandfix", Command_LandfixCheck, "What landfix the replay being spectated was run with");
	RegConsoleCmd("sm_lftoggle", Command_LandfixJumps, "Landfix Toggler");
	RegConsoleCmd("sm_jt", Command_LandfixJumps, "Landfix Jump Toggles menu");
	RegConsoleCmd("sm_lfadd", Command_LandfixJumps, "Landfix Toggler");
	RegConsoleCmd("sm_lfrange", Command_LandfixJumps, "Landfix Toggler");

	gCV_ToggleHints = CreateConVar("landfix_toggle_hints", "1", "Show a hint on screen when a jump toggle fires (1/0)");
	gCV_LandfixDatabase = CreateConVar("sm_landfix_database", "storage-local", "Database entry in databases.cfg used for per-map Landfix jump toggle storage.");


	HookEvent("player_jump", Event_PlayerJump);

	// Cookies -----


gC_SettingsCookie = new Cookie("landfix_settings_v2", "Landfix settings version 2", CookieAccess_Protected);
gC_LegacyEnabledCookie = new Cookie("landfix_toggle", "Landfix toggle state", CookieAccess_Protected);
gC_LegacyLandfixTypeCookie = new Cookie("landfix_type_toggle", "Landfix type toggle state (Haze/NoTimeLoss)", CookieAccess_Protected);
gC_LegacyUseHudCookie = new Cookie("landfix_hud_toggle", "Landfix HUD toggle state", CookieAccess_Protected);
gC_LegacyHudPositionCookie = new Cookie("landfix_hud_position", "Landfix HUD position state", CookieAccess_Protected);
gC_LegacyHudColorCookie = new Cookie("landfix_hud_color", "Landfix HUD Color", CookieAccess_Protected);

GetCurrentMap(gS_LandfixMap, sizeof(gS_LandfixMap));
ConnectLandfixDatabase();

	// NoTimeLoss Stuff -----

	GameData gd = LoadGameConfigFile("landfix.games");
	if (gd == null)
		SetFailState("Failed to load landfix.games gamedata file");

	StartPrepSDKCall(SDKCall_Static);
	if(!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CreateInterface"))
		SetFailState("Failed to get CreateInterface");

	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle CreateInterface = EndPrepSDKCall();

	if(CreateInterface == null)
		SetFailState("Unable to prepare SDKCall for CreateInterface");

	char interfaceName[64];
	if(!GameConfGetKeyValue(gd, "IGameMovement", interfaceName, sizeof(interfaceName)))
		SetFailState("Failed to get IGameMovement interface name");

	Address IGameMovement = SDKCall(CreateInterface, interfaceName, 0);
	if(!IGameMovement)
		SetFailState("Failed to get IGameMovement pointer");

	int offset = GameConfGetOffset(gd, "CheckJumpButton");
	if(offset == -1)
		SetFailState("Failed to get CheckJumpButton offset");

	gH_CheckJumpButtonHookPre = DHookCreate(offset, HookType_Raw, ReturnType_Bool, ThisPointer_Address, DHook_CheckJumpButtonPre);
	DHookRaw(gH_CheckJumpButtonHookPre, false, IGameMovement);

	delete gd;
	delete CreateInterface;

	CreateNative("Landfix_SetHudEditorHidden", Native_Landfix_SetHudEditorHidden);

	// Cookies load and Config Exec -----
	
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client))
			continue;

		if(!IsFakeClient(client))
		{
			OnClientPutInServer(client);
			
			if (AreClientCookiesCached(client))
			    OnClientCookiesCached(client);
		}
	}

	// A bot already playing when this loads never gets its Shavit_OnReplayStart.
	// Deferred because shavit's bot cache is not populated during OnPluginStart.
	CreateTimer(1.0, Timer_LateLoadReplayBots);
	
	AutoExecConfig();

	GetShavitChatColors();
}

// Shavit Chat Color Stuff ----

public void OnMapStart()
{
	GetShavitChatColors();
	gI_HudMapGeneration++;
	GetCurrentMap(gS_LandfixMap, sizeof(gS_LandfixMap));

	// OnMapStart fires while clients may still be loading.  Do not create a HUD
	// timer here: it can fire before the new client HUD exists and then never be
	// restored.  The first player_spawn below performs the restore instead.
	for(int client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client))
		{
			// JumpStats temporarily hides LandFix while its HUD editor is open.
			// A map change closes that editor without its normal exit callback, so
			// restore the saved pre-editor value instead of leaving the HUD off.
			if(gB_EditorHudHidden[client])
			{
				gB_UseHud[client] = gB_EditorHudPrevious[client];
				gB_EditorHudHidden[client] = false;
				gB_EditorHudPrevious[client] = false;
			}

			StopHudTimer(client);

			// Toggles are per-map, so reload (or clear) them for the map we've just landed on.
			if(AreClientCookiesCached(client))
				RequestLandfixToggleLoad(client);
		}
	}
}

public void OnMapEnd()
{
	for(int client = 1; client <= MaxClients; client++)
	{
		StopHudTimer(client);
		StopHudReconnectRestore(client);
	}
}

public Action Timer_RestoreHudAfterMapChange(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);

	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	SetHudPosition(client);
	StartHudTimer(client);
	return Plugin_Stop;
}

public void Shavit_OnChatConfigLoaded()
{
	GetShavitChatColors();
}

void GetShavitChatColors()
{
	Shavit_GetChatStrings(sMessageWarning, gS_Warning, sizeof(gS_Warning));
	Shavit_GetChatStrings(sMessageStyle, gS_Style, sizeof(gS_Style));
}

// Player Stuff --------------------------------------------------

public Action OnPlayerRunCmd(int client, int &buttons) // This is from Haze
{
	if(IsFakeClient(client))
		return Plugin_Continue;

	TrackGround(client);

	int iGroundEnt = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");

	if(gB_Enabled[client] && gB_LandfixType[client] == true)
	{
		if(iGroundEnt != gI_LastGroundEntity[client] && iGroundEnt != -1)
		{
			if(HasEntProp(iGroundEnt, Prop_Data, "m_currentSound")) //retrowave mega fix
			{
				gI_LastGroundEntity[client] = iGroundEnt;
				return Plugin_Continue;
			}

			bool bHasVelocityProp = HasEntProp(iGroundEnt, Prop_Data, "m_vecVelocity");

			if(bHasVelocityProp)
			{
				float fVelocity[3];
				GetEntPropVector(iGroundEnt, Prop_Data, "m_vecVelocity", fVelocity);

				// ground is moving
				if(fVelocity[2] != 0.0)
				{
					gI_LastGroundEntity[client] = iGroundEnt;
					return Plugin_Continue;
				}
			}

			float difference = (1.50 - GetGroundUnits(client)), origin[3];
			GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);
			origin[2] += difference;
			SetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

			if(FloatAbs(difference) > LANDFIX_MARK_EPSILON)
				MarkLandfix(client, 1);
		}
	}

	gI_LastGroundEntity[client] = iGroundEnt;

	return Plugin_Continue;
}

public void OnClientCookiesCached(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || !AreClientCookiesCached(client))
		return;

	// A player can issue a chat command while ClientPrefs is still loading.
	// That deliberate change wins over an older saved value.
	// Keep only fields the player explicitly changed before their cookies
	// loaded. The other fields must still come from their saved record.
	int dirty = gI_PreferencesDirty[client];
	bool enabled = gB_Enabled[client];
	bool type = gB_LandfixType[client];
	bool hud = gB_UseHud[client];
	int position = gI_HudPositionPreset[client];
	int color = gI_HudColor[client];

	bool migrateLegacySettings = LoadLandfixSettings(client);
	bool recoveredHandoffSettings = LoadLandfixHandoffSettings(client);
	if(dirty & PREF_ENABLED)
		gB_Enabled[client] = enabled;
	if(dirty & PREF_TYPE)
		gB_LandfixType[client] = type;
	if(dirty & PREF_HUD)
		gB_UseHud[client] = hud;
	if(dirty & PREF_POSITION)
		gI_HudPositionPreset[client] = position;
	if(dirty & PREF_COLOR)
		gI_HudColor[client] = color;

	gB_PreferencesLoaded[client] = true;
	if(dirty != 0 || migrateLegacySettings || recoveredHandoffSettings)
		SaveLandfixSettings(client, dirty);

// Load this map's Landfix jump toggles (per-map, from the database).
RememberLandfixProfile(client);
RequestLandfixToggleLoad(client);
}

bool LoadLandfixSettings(int client)
{
	char value[64];
	gC_SettingsCookie.Get(client, value, sizeof(value));

	if(ParseLandfixSettings(value, client))
		return false;

	// Existing players get one lossless migration from the original five
	// cookies. New players receive the defaults below.
	gB_Enabled[client] = ReadLegacySetting(gC_LegacyEnabledCookie, client, 1, 0, 1) == 1;
	gB_LandfixType[client] = ReadLegacySetting(gC_LegacyLandfixTypeCookie, client, 0, 0, 1) == 1;
	gB_UseHud[client] = ReadLegacySetting(gC_LegacyUseHudCookie, client, 1, 0, 1) == 1;
	gI_HudPositionPreset[client] = ReadLegacySetting(gC_LegacyHudPositionCookie, client, 0, 0, 2);
	gI_HudColor[client] = ReadLegacySetting(gC_LegacyHudColorCookie, client, 0, 0, sizeof(gI_ColorRGB) - 1);
	return true;
}

bool ParseLandfixSettings(const char[] value, int client)
{
	char fields[6][8];
	int version;
	if(ExplodeString(value, "|", fields, sizeof(fields), sizeof(fields[])) != 6
		|| !TryParseCookieInt(fields[0], version) || version != 2)
	{
		return false;
	}

	int enabled, type, hud, position, color;
	if(!TryParseCookieInt(fields[1], enabled) || !TryParseCookieInt(fields[2], type)
		|| !TryParseCookieInt(fields[3], hud) || !TryParseCookieInt(fields[4], position)
		|| !TryParseCookieInt(fields[5], color))
	{
		return false;
	}

	if((enabled != 0 && enabled != 1) || (type != 0 && type != 1)
		|| (hud != 0 && hud != 1) || position < 0 || position > 2
		|| color < 0 || color >= sizeof(gI_ColorRGB))
	{
		return false;
	}

	gB_Enabled[client] = enabled == 1;
	gB_LandfixType[client] = type == 1;
	gB_UseHud[client] = hud == 1;
	gI_HudPositionPreset[client] = position;
	gI_HudColor[client] = color;
	return true;
}

int ReadLegacySetting(Cookie cookie, int client, int fallback, int minimum, int maximum)
{
	char value[12];
	cookie.Get(client, value, sizeof(value));

	if(value[0] == '\0')
		return fallback;

	int result;
	if(!TryParseCookieInt(value, result))
		return fallback;

	return (result < minimum || result > maximum) ? fallback : result;
}

bool TryParseCookieInt(const char[] value, int &result)
{
	if(value[0] == '\0')
		return false;

	result = 0;
	for(int i = 0; value[i] != '\0'; i++)
	{
		if(value[i] < '0' || value[i] > '9')
			return false;

		result = (result * 10) + (value[i] - '0');
	}

	return true;
}

void SaveLandfixSettings(int client, int changed = 0)
{
	gI_PreferencesDirty[client] |= changed;

	if(!gB_PreferencesLoaded[client] || !AreClientCookiesCached(client))
		return;

	char value[32];
	Format(value, sizeof(value), "2|%d|%d|%d|%d|%d", gB_Enabled[client], gB_LandfixType[client],
		gB_UseHud[client], gI_HudPositionPreset[client], gI_HudColor[client]);
	gC_SettingsCookie.Set(client, value);
	SaveLegacyLandfixSettings(client);
	if(changed != 0)
		SaveLandfixHandoffSettings(client, value);
	gI_PreferencesDirty[client] = 0;
}

bool GetLandfixHandoffAuthId(int client, char[] authId, int maxlen)
{
	return GetClientAuthId(client, AuthId_Steam2, authId, maxlen, true)
		&& !StrEqual(authId, "STEAM_ID_LAN") && !StrEqual(authId, "STEAM_ID_PENDING") && !StrEqual(authId, "BOT");
}

void SaveLandfixHandoffSettings(int client, const char[] value)
{
	char authId[MAX_AUTHID_LENGTH];
	if(!GetLandfixHandoffAuthId(client, authId, sizeof(authId)))
		return;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), LANDFIX_HANDOFF_FILE);

	KeyValues handoff = new KeyValues("LandfixSettingsHandoff");
	if(FileExists(path))
		handoff.ImportFromFile(path);

	handoff.Rewind();
	handoff.JumpToKey(authId, true);
	handoff.SetString("value", value);
	handoff.SetNum("updated", GetTime());
	handoff.Rewind();
	handoff.ExportToFile(path);
	delete handoff;
}

bool LoadLandfixHandoffSettings(int client)
{
	char authId[MAX_AUTHID_LENGTH];
	if(!GetLandfixHandoffAuthId(client, authId, sizeof(authId)))
		return false;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), LANDFIX_HANDOFF_FILE);
	if(!FileExists(path))
		return false;

	KeyValues handoff = new KeyValues("LandfixSettingsHandoff");
	if(!handoff.ImportFromFile(path))
	{
		delete handoff;
		return false;
	}

	handoff.Rewind();
	if(!handoff.JumpToKey(authId, false))
	{
		delete handoff;
		return false;
	}

	char value[32];
	handoff.GetString("value", value, sizeof(value));
	int updated = handoff.GetNum("updated", 0);
	delete handoff;

	// The handoff only wins when it is at least as new as the database value.
	// This makes it a transition safeguard, not a replacement for ClientPrefs.
	if(value[0] == '\0' || updated < gC_SettingsCookie.GetClientTime(client))
		return false;

	return ParseLandfixSettings(value, client);
}

void SaveLegacyLandfixSettings(int client)
{
	char value[12];

	IntToString(gB_Enabled[client], value, sizeof(value));
	gC_LegacyEnabledCookie.Set(client, value);

	IntToString(gB_LandfixType[client], value, sizeof(value));
	gC_LegacyLandfixTypeCookie.Set(client, value);

	IntToString(gB_UseHud[client], value, sizeof(value));
	gC_LegacyUseHudCookie.Set(client, value);

	IntToString(gI_HudPositionPreset[client], value, sizeof(value));
	gC_LegacyHudPositionCookie.Set(client, value);

	IntToString(gI_HudColor[client], value, sizeof(value));
	gC_LegacyHudColorCookie.Set(client, value);
}

public void OnClientPutInServer(int client)
{
	// These values are only temporary until ClientPrefs invokes
	// OnClientCookiesCached. Never read or write a cookie from this callback.
	gB_Enabled[client] = true;
	gB_LandfixType[client] = false;
	gB_UseHud[client] = true;
	gI_HudPositionPreset[client] = 0;
	gI_HudColor[client] = 0;
	gB_PreferencesLoaded[client] = false;
	gI_PreferencesDirty[client] = 0;

	gB_WasOnGround[client] = false;
	gI_LastTakeoffTick[client] = 0;
	gI_LastJumps[client] = 0;
	delete gA_LandfixTargets[client];

	gB_LandfixJumpsEnabled[client] = true;
	gI_LandfixLastToggleTick[client] = 0;
	CloseLandfixWindow(client);
	gB_LandfixBaseState[client] = false;
	gB_LandfixRangeActive[client] = false;
	ClearLandfixMarks(client);

	// ClientPrefs can finish loading either before or shortly after the player
	// enters the server. Retry the HUD start for a few seconds so a reconnect
	// cannot leave a valid saved preference with no running HUD timer.
	QueueHudReconnectRestore(client);
}

public void OnClientDisconnect(int client)
{
	// The repeating HUD timer was left running on a raw client index. It only
	// stopped itself on its next fire, so it could tick for whoever took the
	// slot in between.
	StopHudTimer(client);
	StopHudReconnectRestore(client);

	gB_EditorHudHidden[client] = false;
	gB_EditorHudPrevious[client] = false;
	gI_HudRestoredGeneration[client] = 0;

	delete gA_LandfixTargets[client];
	gB_LandfixWindowActive[client] = false;
	gB_LandfixRangeActive[client] = false;
	ClearLandfixMarks(client);
	ClearFinishedSnapshot(client);
}
// Commands --------------------------------------------------

public Action Command_LandFix(int client, int args) 
{
	if (client == 0)
		return Plugin_Handled;

	SetLandfixEnabled(client, !gB_Enabled[client], true);
	PrintLandfixState(client);
	
	return Plugin_Handled;
}

void SetLandfixEnabled(int client, bool enabled, bool savePreference)
{
	gB_Enabled[client] = enabled;
	MarkLandfixState(client);

	if(savePreference)
		SaveLandfixSettings(client, PREF_ENABLED);

	StartHudTimer(client);
}

void PrintLandfixState(int client)
{
	if(!gB_Enabled[client])
	{
		Shavit_PrintToChat(client, "Landfix: " ... C_RED ... "Off");
		return;
	}

	Shavit_PrintToChat(client, "Landfix: " ... C_GREEN ... "On \x07ffffff(%s)",
		gB_LandfixType[client] ? "Haze" : "NoTimeLoss");
}

public Action Command_LandFixType(int client, int args) 
{
    if(client == 0)
        return Plugin_Handled;

    gB_LandfixType[client] = !gB_LandfixType[client];
    MarkLandfixState(client);
    
    SaveLandfixSettings(client, PREF_TYPE);
    
    SetHudPosition(client);
    RefreshHudDisplay(client);
    
    if(gB_LandfixType[client])
        Shavit_PrintToChat(client, "Landfix Type: %sHaze", gS_Warning);
    else
        Shavit_PrintToChat(client, "Landfix Type: %sNoTimeLoss", gS_Style);
    return Plugin_Handled;
}

public Action Command_LandFixHud(int client, int args) 
{
	if (client == 0)
		return Plugin_Handled;
	
	gB_UseHud[client] = !gB_UseHud[client];
	if(gB_UseHud[client])
		Shavit_PrintToChat(client, "Landfix HUD: %sOn", gS_Warning);
	else
		Shavit_PrintToChat(client, "Landfix HUD: %sOff", gS_Style);
	
	SaveLandfixSettings(client, PREF_HUD);
	
	if (gB_UseHud[client])
		StartHudTimer(client);
	else
		StopHudTimer(client);
	
	return Plugin_Handled;
}

public Action Command_LandFixHudColor(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;
	
	if (args < 1)
	{
		Shavit_PrintToChat(client, "Choose a HUD color from 0 to 5, example: %s/lfhc 1", gS_Style);
		Shavit_PrintToChat(client, "Current Landfix HUD color: " ... C_PINK ... "%d", gI_HudColor[client]);

		ShowLandFixHudColorMenu(client);

		return Plugin_Handled;
	}
	
	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int color = StringToInt(arg);
	if (color < 0 || color >= 6)
	{
		Shavit_PrintToChat(client, "Choose a HUD color from 0 to 5, example: %s/lfhc 1", gS_Style);
		Shavit_PrintToChat(client, "Current Landfix HUD color: " ... C_PINK ... "%d", gI_HudColor[client]);
		return Plugin_Handled;
	}
	
	gI_HudColor[client] = color;

	SaveLandfixSettings(client, PREF_COLOR);
	
	// Refresh HUD display with new color
	RefreshHudDisplay(client);
	
	Shavit_PrintToChat(client, "Landfix HUD color set to: " ... C_PINK ... "%d", color);
	return Plugin_Handled;
}

public Action Command_LandFixMenu(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;
	
	ShowLandFixMenu(client);

	return Plugin_Handled;
}

public Action Command_LandFixCommandsMenu(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;
	
	ShowLandFixCommandsMenu(client);

	return Plugin_Handled;
}

public Action Command_LandFixAboutMenu(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;
	
	ShowLandFixAboutMenu(client);

	return Plugin_Handled;
}

// Menus --------------------------------------------------

void ShowLandFixMenu(int client)
{
	Menu menu = CreateMenu(LandFixMenu_Callback);
	SetMenuTitle(menu, "Landfix\n \n");

	AddMenuItem(menu, "landfix", (gB_Enabled[client]) ? "Landfix: On" : "Landfix: Off");
	AddMenuItem(menu, "lftype", (gB_LandfixType[client]) ? "Type: Haze\n \n" : "Type: NoTimeLoss\n \n");

	AddMenuItem(menu, "lfhud", (gB_UseHud[client]) ? "HUD: On" : "HUD: Off");
	AddMenuItem(menu, "lfhudpos", "HUD Position");
	AddMenuItem(menu, "lfhudcolor", "HUD Color\n \n");

	AddMenuItem(menu, "lfcommands", "Commands");
	AddMenuItem(menu, "lfabout", "About");

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandFixMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));
		
		if(StrEqual(info, "landfix"))
		{
			Command_LandFix(client, 0);
			ShowLandFixMenu(client);
		}
		else if(StrEqual(info, "lftype"))
		{
			Command_LandFixType(client, 0);
			ShowLandFixMenu(client);
		}
		else if(StrEqual(info, "lfhud"))
		{
			Command_LandFixHud(client, 0);
			ShowLandFixMenu(client);
		}
		else if(StrEqual(info, "lfhudpos"))
		{
			ShowLandFixHudPosMenu(client);
		}
		else if(StrEqual(info, "lfhudcolor"))
		{
			ShowLandFixHudColorMenu(client);
		}
		else if(StrEqual(info, "lfcommands"))
		{
			ShowLandFixCommandsMenu(client);
		}
		else if(StrEqual(info, "lfabout"))
		{
			ShowLandFixAboutMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowLandFixHudPosMenu(int client)
{
	Menu menu = CreateMenu(LandFixHudPosMenu_Callback);
	SetMenuTitle(menu, "Landfix | HUD Position\n \n");
	AddMenuItem(menu, "0", "Top Left (Default)");
	AddMenuItem(menu, "1", "Top Right");
	AddMenuItem(menu, "2\n \n", "Top Center\n \n");
	AddMenuItem(menu, "back", "Back");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandFixHudPosMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));
		
		if(StrEqual(info, "back"))
		{
			ShowLandFixMenu(client);
		}
		else
		{
			int hudPos = StringToInt(info);
			gI_HudPositionPreset[client] = hudPos;
			SetHudPosition(client);
			
			SaveLandfixSettings(client, PREF_POSITION);
			
			// Refresh HUD display with new position
			RefreshHudDisplay(client);
			
			char posName[16];
			switch(hudPos)
			{
				case 1: strcopy(posName, sizeof(posName), "Top Right");
				case 2: strcopy(posName, sizeof(posName), "Top Center");
				default: strcopy(posName, sizeof(posName), "Top Left");
			}
			Shavit_PrintToChat(client, "Landfix HUD set to: " ... C_PINK ... "%s", posName);
			ShowLandFixHudPosMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowLandFixHudColorMenu(int client)
{
	Menu menu = CreateMenu(LandFixHudColorMenu_Callback);
	SetMenuTitle(menu, "Landfix | HUD Color\n \n");
	AddMenuItem(menu, "0", "White (Default)");
	AddMenuItem(menu, "1", "Cyan");
	AddMenuItem(menu, "2", "Purple");
	AddMenuItem(menu, "3", "Yellow");
	AddMenuItem(menu, "4", "Green");
	AddMenuItem(menu, "5\n \n", "Red\n \n");
	AddMenuItem(menu, "back", "Back");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandFixHudColorMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));
		
		if(StrEqual(info, "back"))
		{
			ShowLandFixMenu(client);
		}
		else
		{
			int colorIndex = StringToInt(info);
			gI_HudColor[client] = colorIndex;
			SaveLandfixSettings(client, PREF_COLOR);
			
			// Refresh HUD display with new color
			RefreshHudDisplay(client);
			
			Shavit_PrintToChat(client, "Landfix HUD color set to: " ... C_PINK ... "%d", colorIndex);
			ShowLandFixHudColorMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowLandFixCommandsMenu(int client)
{
	Menu menu = CreateMenu(LandFixCommandsMenu_Callback);
	SetMenuTitle(menu, "Landfix | Commands\n \n/lf - Toggle Landfix (On/Off)\n/lfs - Toggle Type (NoTimeLoss/Haze)\n \n/lft - Jump toggles, or /lft 5 7 10-12\n \n/lfh - Toggle Landfix Hud (On/Off)\n/lfhc <number> - Set Hud Color (0-5)\n \n/lfc - Landfix of the replay you spectate\n \n/lfm - Open Landfix Main Menu\n/lfi - Open Landfix Commands Menu\n/lfa - Open Landfix About Menu\n \n");
	AddMenuItem(menu, "back", "Back");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandFixCommandsMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));
		
		if(StrEqual(info, "back"))
			ShowLandFixMenu(client);
	}

	return 0;
}

void ShowLandFixAboutMenu(int client)
{
	char sVersion[8], sName[64];
	GetPluginInfo(GetMyHandle(), PlInfo_Version, sVersion, sizeof(sVersion));
	GetPluginInfo(GetMyHandle(), PlInfo_Name, sName, sizeof(sName));

	Menu menu = CreateMenu(LandFixAboutMenu_Callback);
	SetMenuTitle(menu, "%s v%s\n \nThe Landfix plugin fixes a Source engine bug that causes jump height to vary by 2 units every jump\n \n \nLandfix Types:\n \nNoTimeLoss - Balances jump height by increasing the minimum height by 0.5 units while decreasing the maximum height by 0.5 units\nYou won't have any time loss during your run\n \nHaze - Makes every jump reach the maximum height, making 64-unit crouch jumps the easiest to perform\nYou will have a slight time loss by the end of your run\n \n", sName, sVersion);
	AddMenuItem(menu, "back", "Back");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandFixAboutMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));
		
		if(StrEqual(info, "back"))
			ShowLandFixMenu(client);
	}

	return 0;
}

// HUD Timer Logic --------------------------------------------------

// Hud Timer
public Action Timer_ShowHudText(Handle timer, any client)
{
	// Validate client and settings
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)
		|| !gB_PreferencesLoaded[client] || !gB_UseHud[client])
	{
		if(client >= 1 && client <= MaxClients && gH_hudTimers[client] == timer)
			gH_hudTimers[client] = null;
		return Plugin_Stop;
	}

	if (gH_hudTimers[client] != timer)
		return Plugin_Stop;

	char hudText[64];
	int target = SpectatedTarget(client);
	bool draw;

	// Watching a replay: what that run had set at the point on screen. Watching a
	// player: theirs, since that is whose jumps are being looked at. Otherwise their
	// own. All three draw the same line, or none at all.
	if(g_bReplayPlayback && target > 0 && Shavit_IsReplayEntity(target))
		draw = gB_BotMarksKnown[target] && FormatBotLandfixHud(target, hudText, sizeof(hudText));
	else if(target > 0 && !IsFakeClient(target))
		draw = FormatClientLandfixHud(target, hudText, sizeof(hudText));
	else
		draw = FormatClientLandfixHud(client, hudText, sizeof(hudText));

	// The timer keeps running with landfix off, because they may spectate at any
	// moment, so there has to be something to clear the line it last drew.
	if(!draw)
	{
		SetHudTextParams(-1.0, -1.0, 0.01, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
		ClearSyncHud(client, gH_HudSync);
		return Plugin_Continue;
	}

	SetHudTextParams(gF_HudPositionX[client], gF_HudPositionY[client], gF_HudTimerDuration + LANDFIX_HUD_HOLD_BUFFER,
        gI_ColorRGB[gI_HudColor[client]][0],
        gI_ColorRGB[gI_HudColor[client]][1],
        gI_ColorRGB[gI_HudColor[client]][2],
        gI_ColorRGB[gI_HudColor[client]][3],
        0, 0.0, 0.0, 0.0);

	ShowSyncHudText(client, gH_HudSync, "%s", hudText);

	return Plugin_Continue;
}

void StopHudTimer(int client)
{
	if (gH_hudTimers[client] != null)
	{
		Handle timer = gH_hudTimers[client];
		gH_hudTimers[client] = null;
		KillTimer(timer);
	}

	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	// Clear any existing HUD text
	SetHudTextParams(-1.0, -1.0, 0.01, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
	ClearSyncHud(client, gH_HudSync);
}

void StartHudTimer(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client) || !gB_PreferencesLoaded[client])
		return;

	// Always stop any existing timer first
	StopHudTimer(client);

	if (gB_UseHud[client])
		gH_hudTimers[client] = CreateTimer(gF_HudTimerDuration, Timer_ShowHudText, client, TIMER_REPEAT);
}

void QueueHudReconnectRestore(int client)
{
	StopHudReconnectRestore(client);

	gI_HudReconnectUserId[client] = GetClientUserId(client);
	gI_HudReconnectAttempts[client] = 0;
	gH_HudReconnectTimers[client] = CreateTimer(0.5, Timer_RestoreHudAfterReconnect, client, TIMER_REPEAT);
}

void StopHudReconnectRestore(int client)
{
	if(gH_HudReconnectTimers[client] != null)
	{
		Handle timer = gH_HudReconnectTimers[client];
		gH_HudReconnectTimers[client] = null;
		KillTimer(timer);
	}

	gI_HudReconnectUserId[client] = 0;
	gI_HudReconnectAttempts[client] = 0;
}

public Action Timer_RestoreHudAfterReconnect(Handle timer, any client)
{
	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client)
		|| gH_HudReconnectTimers[client] != timer
		|| GetClientUserId(client) != gI_HudReconnectUserId[client])
	{
		if(client >= 1 && client <= MaxClients && gH_HudReconnectTimers[client] == timer)
		{
			gH_HudReconnectTimers[client] = null;
			gI_HudReconnectUserId[client] = 0;
			gI_HudReconnectAttempts[client] = 0;
		}

		return Plugin_Stop;
	}

	if(AreClientCookiesCached(client))
	{
		gH_HudReconnectTimers[client] = null;
		gI_HudReconnectUserId[client] = 0;
		gI_HudReconnectAttempts[client] = 0;
		if(!gB_PreferencesLoaded[client])
			OnClientCookiesCached(client);

		SetHudPosition(client);
		StartHudTimer(client);
		return Plugin_Stop;
	}

	if(++gI_HudReconnectAttempts[client] >= 20)
	{
		gH_HudReconnectTimers[client] = null;
		gI_HudReconnectUserId[client] = 0;
		gI_HudReconnectAttempts[client] = 0;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

void SetHudPosition(int client)
{
    // Top Left
    if (gI_HudPositionPreset[client] == 0)
    {
        gF_HudPositionX[client] = 0.01;
        gF_HudPositionY[client] = 0.16;
        return;
    }

    // Top Right: compute x so the RIGHT edge of the text lands a fixed margin
    // from the screen edge (right-anchored). Now that HudMessage is full-screen
    // (f0 x f0 in HudLayout.res), x/y are true fractions of the screen.
    // charWidth is the fraction of screen width one character occupies at the
    // default CS:S HUD font scale on a 16:9 display. The right margin keeps the
    // text from touching the absolute edge.
    if (gI_HudPositionPreset[client] == 1)
    {
        // "Landfix: NoTimeLoss" = 15 chars, "Landfix: Haze" = 13 chars
        int chars = gB_LandfixType[client] ? 13 : 19;
        float charWidth = 0.0096;
        float rightMargin = 0.01;
        gF_HudPositionX[client] = 1.0 - rightMargin - (float(chars) * charWidth);
        gF_HudPositionY[client] = 0.01;
        return;
    }

    // Top Center, and anything that is not Top Left/Top Right
    if (gB_LandfixType[client] == true)
        gF_HudPositionX[client] = 0.444;
    else
        gF_HudPositionX[client] = 0.443;

    gF_HudPositionY[client] = 0.01;
}

void RefreshHudDisplay(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;
		
	// Stop current timer and restart with new settings
	StartHudTimer(client);
}

public int Native_Landfix_SetHudEditorHidden(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool hidden = view_as<bool>(GetNativeCell(2));

	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return false;
	}

	if(hidden)
	{
		if(!gB_EditorHudHidden[client])
		{
			gB_EditorHudPrevious[client] = gB_UseHud[client];
			gB_EditorHudHidden[client] = true;

			if(gB_UseHud[client])
			{
				StopHudTimer(client);
			}

			gB_UseHud[client] = false;
		}

		return true;
	}

	if(gB_EditorHudHidden[client])
	{
		gB_UseHud[client] = gB_EditorHudPrevious[client];
		gB_EditorHudHidden[client] = false;
		gB_EditorHudPrevious[client] = false;

		if(gB_UseHud[client])
		{
			StartHudTimer(client);
		}
	}

	return true;
}

// Actual LandFix Logic --------------------------------------------------

// NoTimeLoss Logic -----

MRESReturn DHook_CheckJumpButtonPre(Address pThis, Handle hParams)
{
	Address mv = view_as<Address>(LoadFromAddress(pThis + view_as<Address>(0x8), NumberType_Int32));
	int client = LoadFromAddress(mv + view_as<Address>(0x4), NumberType_Int32) & 0xFFFF;

	if(client < 1 || client > MaxClients)
		return MRES_Ignored;

	if(IsFakeClient(client) || !IsPlayerAlive(client))
		return MRES_Ignored;

	if(!gB_Enabled[client] || gB_LandfixType[client] == true)
		return MRES_Ignored;

	if(!GetEntPropFloat(client, Prop_Data, "m_flWaterJumpTime"))
	{
		if(GetEntProp(client, Prop_Data, "m_nWaterLevel") >= 2 || GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") == -1)
			return MRES_Ignored;

		int mv_old_buttons = LoadFromAddress(mv + view_as<Address>(0x28), NumberType_Int32);
		if(mv_old_buttons & IN_JUMP || mv_old_buttons & IN_DUCK)
			return MRES_Ignored;

		float origin[3];
		float grndPos[3];
		origin[0] = view_as<float>(LoadFromAddress(mv + view_as<Address>(0x9C + 0x0), NumberType_Int32));
		origin[1] = view_as<float>(LoadFromAddress(mv + view_as<Address>(0x9C + 0x4), NumberType_Int32));
		origin[2] = view_as<float>(LoadFromAddress(mv + view_as<Address>(0x9C + 0x8), NumberType_Int32));
		// The original returned void and left grndPos zeroed when the trace
		// missed, which made diff a garbage value instead of a no-op.
		if(!GetGroundPosition(client, origin, grndPos))
			return MRES_Ignored;

		float diff = FloatAbs(grndPos[2] - origin[2]);
		if(diff < 0.49)
		{
			origin[2] = grndPos[2] + 0.49;
			StoreToAddress(mv + view_as<Address>(0x9C + 0x0), view_as<int>(origin[0]), NumberType_Int32);
			StoreToAddress(mv + view_as<Address>(0x9C + 0x4), view_as<int>(origin[1]), NumberType_Int32);
			StoreToAddress(mv + view_as<Address>(0x9C + 0x8), view_as<int>(origin[2]), NumberType_Int32);
			MarkLandfix(client, 0);
		}
		else if(diff > 1.5 && diff < 2.0)
		{
			origin[2] = grndPos[2] + 1.5;
			StoreToAddress(mv + view_as<Address>(0x9C + 0x0), view_as<int>(origin[0]), NumberType_Int32);
			StoreToAddress(mv + view_as<Address>(0x9C + 0x4), view_as<int>(origin[1]), NumberType_Int32);
			StoreToAddress(mv + view_as<Address>(0x9C + 0x8), view_as<int>(origin[2]), NumberType_Int32);
			MarkLandfix(client, 0);
		}
	}
	return MRES_Ignored;
}

bool GetGroundPosition(int client, float origin[3], float out[3])
{
	float originBelow[3], landingMins[3], landingMaxs[3];
	GetEntPropVector(client, Prop_Data, "m_vecMins", landingMins);
	GetEntPropVector(client, Prop_Data, "m_vecMaxs", landingMaxs);

	originBelow[0] = origin[0];
	originBelow[1] = origin[1];
	originBelow[2] = origin[2] - 2.0;

	TR_TraceHullFilter(origin, originBelow, landingMins, landingMaxs, MASK_PLAYERSOLID, PlayerFilter, client);
	if(!TR_DidHit())
		return false;

	TR_GetEndPosition(out, null);

	return true;
}

// Haze Logic -----

//Thanks MARU for the idea/http://steamcommunity.com/profiles/76561197970936804 | comment from Haze
float GetGroundUnits(int client)
{
	if (!IsPlayerAlive(client) || GetEntityMoveType(client) != MOVETYPE_WALK || GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
		return 0.0;

	float origin[3], originBelow[3], landingMins[3], landingMaxs[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);
	GetEntPropVector(client, Prop_Data, "m_vecMins", landingMins);
	GetEntPropVector(client, Prop_Data, "m_vecMaxs", landingMaxs);

	originBelow[0] = origin[0];
	originBelow[1] = origin[1];
	originBelow[2] = origin[2] - 2.0;

	TR_TraceHullFilter(origin, originBelow, landingMins, landingMaxs, MASK_PLAYERSOLID, PlayerFilter, client);

	if(TR_DidHit())
	{
		TR_GetEndPosition(originBelow, null);
		float defaultheight = originBelow[2] - RoundToFloor(originBelow[2]);

		if(defaultheight > 0.03125)
			defaultheight = 0.03125;

		float heightbug = origin[2] - originBelow[2] + defaultheight;
		return heightbug;
	}
	else
	{
		return 0.0;
	}
}

public bool PlayerFilter(int entity, int mask)
{
	return !(1 <= entity <= MaxClients);
}

// Commands -------------------------------------------------------------------

public Action Command_LandfixJumps(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;

	if(args == 0)
	{
		ShowToggleMenu(client);
		return Plugin_Handled;
	}

	char rest[256], arg[32];

	for(int i = 1; i <= args; i++)
	{
		GetCmdArg(i, arg, sizeof(arg));
		Format(rest, sizeof(rest), "%s %s", rest, arg);
	}

	if(AddLandfixTargetsFromString(client, rest) == 0)
	{
		Shavit_PrintToChat(client,
			"Nothing added. Example: %s/lft 5 7 10-12",
			gS_Style);
		return Plugin_Handled;
	}

	SaveLandfixToggles(client);

	char list[256];
	BuildLandfixList(client, list, sizeof(list));

	Shavit_PrintToChat(client,
		"Landfix jumps: %s%s",
		gS_Warning,
		list);

	return Plugin_Handled;
}


// Menus ---------------------------------------------------------------------

void ShowToggleMenu(int client)
{
	Menu menu = CreateMenu(LandfixToggleMenu_Callback);
	SetMenuTitle(menu, "Landfix Jump Toggles\n \n");

	char item[64];

	Format(item, sizeof(item),
		"Landfix: %s, %d set\n \n",
		gB_LandfixJumpsEnabled[client] ? "On" : "Off",
		TargetCount(client));

	AddMenuItem(menu, "landfix", item);
	AddMenuItem(menu, "clear", "Clear all Landfix toggles");
	AddMenuItem(menu, "browse", "Browse other players' toggles\n \n");
	AddMenuItem(menu, "status", "Show status");

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LandfixToggleMenu_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_End)
	{
		delete menu;
		return 0;
	}

	if(action != MenuAction_Select)
		return 0;

	char info[32];
	GetMenuItem(menu, option, info, sizeof(info));

	if(StrEqual(info, "landfix"))
	{
		gB_LandfixJumpsEnabled[client] = !gB_LandfixJumpsEnabled[client];

		if(!gB_LandfixJumpsEnabled[client] && gB_LandfixWindowActive[client])
		{
			bool flipped;

			gI_LandfixLastToggleTick[client] = 0;

			SetLandfixJumpState(
				client,
				gB_LandfixBaseState[client],
				flipped
			);

			CloseLandfixWindow(client);

			if(flipped)
			{
				NotifyLandfixJump(
					client,
					gB_LandfixBaseState[client],
					0,
					0
				);
			}
		}

		SaveLandfixToggles(client);
		ShowToggleMenu(client);
	}
	else if(StrEqual(info, "clear"))
	{
		ClearLandfixTargets(client);
		SaveLandfixToggles(client);

		ResetLandfixJumps(client);

		Shavit_PrintToChat(client, "Cleared all Landfix jump toggles.");

		ShowToggleMenu(client);
	}
	else if(StrEqual(info, "browse"))
	{
		ShowLandfixToggleBrowseMenu(client);
	}
	else if(StrEqual(info, "status"))
	{
		PrintLandfixJumpStatus(client);
		ShowToggleMenu(client);
	}

	return 0;
}


// Landfix marks -------------------------------------------------------------

// Both landfix types come through here, so what counts as part of a run is
// decided in one place. mode matches gB_LandfixType: 0 = NoTimeLoss, 1 = Haze.
void MarkLandfix(int client, int mode)
{
	if(client < 1 || client > MaxClients || IsFakeClient(client))
		return;

	if(Shavit_GetTimerStatus(client) != Timer_Running)
		return;

	if(gA_LandfixMarks[client] == null)
		gA_LandfixMarks[client] = new ArrayList(3);

	if(gA_LandfixMarks[client].Length >= LANDFIX_MARK_MAX)
	{
		gB_LandfixMarksFull[client] = true;
		return;
	}

	int index = gA_LandfixMarks[client].Push(Shavit_GetClientTime(client));
	gA_LandfixMarks[client].Set(index, Shavit_GetClientJumps(client), 1);
	gA_LandfixMarks[client].Set(index, mode, 2);
}

void ClearLandfixMarks(int client)
{
	delete gA_LandfixMarks[client];
	delete gA_LandfixStates[client];
	gB_LandfixMarksFull[client] = false;
}

void ClearFinishedSnapshot(int client)
{
	delete gA_FinishedMarks[client];
	delete gA_FinishedStates[client];
	gB_FinishedTruncated[client] = false;
	gB_FinishedEnabled[client] = false;
	gB_FinishedMode[client] = false;
	gB_HaveFinished[client] = false;
}

// Only what changed mid-run. The state the run started on is written by
// Shavit_OnStart, which is the one entry that is not a change.
void MarkLandfixState(int client)
{
	if(client < 1 || client > MaxClients || IsFakeClient(client))
		return;

	if(Shavit_GetTimerStatus(client) != Timer_Running)
		return;

	PushLandfixState(client, Shavit_GetClientTime(client));
}

void PushLandfixState(int client, float time)
{
	if(gA_LandfixStates[client] == null)
		gA_LandfixStates[client] = new ArrayList(3);

	// A toggle and its cooldown can land on the same tick. Two entries at one time
	// only make the run look busier than it was.
	int length = gA_LandfixStates[client].Length;

	if(length > 0)
	{
		int last = length - 1;

		if(gA_LandfixStates[client].Get(last, 1) == (gB_Enabled[client] ? 1 : 0)
			&& gA_LandfixStates[client].Get(last, 2) == (gB_LandfixType[client] ? 1 : 0))
			return;
	}

	if(length >= LANDFIX_MARK_MAX)
		return;

	int index = gA_LandfixStates[client].Push(time);
	gA_LandfixStates[client].Set(index, gB_Enabled[client] ? 1 : 0, 1);
	gA_LandfixStates[client].Set(index, gB_LandfixType[client] ? 1 : 0, 2);
}

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
	// The next attempt's Shavit_OnStart can fire before the replay is written.
	ClearFinishedSnapshot(client);

	if(gA_LandfixMarks[client] != null)
		gA_FinishedMarks[client] = gA_LandfixMarks[client].Clone();

	if(gA_LandfixStates[client] != null)
		gA_FinishedStates[client] = gA_LandfixStates[client].Clone();

	gB_FinishedTruncated[client] = gB_LandfixMarksFull[client];
	gB_FinishedEnabled[client] = gB_Enabled[client];
	gB_FinishedMode[client] = gB_LandfixType[client];
	gB_HaveFinished[client] = true;
}

public Action Shavit_OnStart(int client, int track)
{
	ClearLandfixMarks(client);
	// What the run is starting on. Everything after this is a change.
	PushLandfixState(client, 0.0);

	return Plugin_Continue;
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
	if(client < 1 || client > MaxClients || replaypaths == null)
		return;

	char path[PLATFORM_MAX_PATH];

	// A run can be written to more than one path. Each copy gets its own file so
	// the marks are beside whichever one is read later.
	for(int i = 0; i < replaypaths.Length; i++)
	{
		replaypaths.GetString(i, path, sizeof(path));
		WriteLandfixMarks(client, path, jumps, time);
	}

	ClearFinishedSnapshot(client);
}

// Written for every run, including the ones with nothing to report: a file
// saying zero is what separates "landfix did nothing here" from "this run is
// older than the marks".
void WriteLandfixMarks(int client, const char[] replayPath, int jumps, float time)
{
	char path[PLATFORM_MAX_PATH];
	FormatEx(path, sizeof(path), "%s.landfix", replayPath);

	File file = OpenFile(path, "w");

	if(file == null)
		return;

	// Falls back to live state for any caller outside a finished run.
	bool snap = gB_HaveFinished[client];
	ArrayList marks = snap ? gA_FinishedMarks[client] : gA_LandfixMarks[client];
	int count = (marks == null) ? 0 : marks.Length;

	file.WriteLine("version %d", LANDFIX_MARK_VERSION);
	file.WriteLine("auth %d", GetSteamAccountID(client, false));
	file.WriteLine("time %.8f", time);
	file.WriteLine("enabled %d", (snap ? gB_FinishedEnabled[client] : gB_Enabled[client]) ? 1 : 0);
	file.WriteLine("mode %d", (snap ? gB_FinishedMode[client] : gB_LandfixType[client]) ? 1 : 0);
	file.WriteLine("jumps %d", jumps);
	file.WriteLine("truncated %d", (snap ? gB_FinishedTruncated[client] : gB_LandfixMarksFull[client]) ? 1 : 0);
	file.WriteLine("count %d", count);

	for(int i = 0; i < count; i++)
	{
		float marktime = marks.Get(i, 0);
		file.WriteLine("mark %.6f %d %d", marktime, marks.Get(i, 1), marks.Get(i, 2));
	}

	ArrayList states = snap ? gA_FinishedStates[client] : gA_LandfixStates[client];
	int changes = (states == null) ? 0 : states.Length;

	for(int i = 0; i < changes; i++)
	{
		float statetime = states.Get(i, 0);
		file.WriteLine("state %.6f %d %d", statetime, states.Get(i, 1), states.Get(i, 2));
	}

	delete file;
}

// Replay marks --------------------------------------------------------------

// Says what the replay being watched was run with, and says plainly when there is
// nothing to say. A run with no marks beside it is not a run without landfix: it
// was set before any of this was recorded, or on another server entirely, and the
// HUD's silence on its own does not tell those apart.
// The colour belongs to the state rather than the text, so a label is put together
// at runtime instead of with the literal concatenation the fixed messages use.
void LandfixStateLabel(bool on, int mode, char[] buffer, int maxlen)
{
	if(!on)
		FormatEx(buffer, maxlen, "%sOff", C_RED);
	else
		FormatEx(buffer, maxlen, "%s%s", C_GREEN, (mode == 1) ? "Haze" : "NoTimeLoss");
}

public Action Command_LandfixCheck(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;

	int target = SpectatedTarget(client);

	if(!g_bReplayPlayback)
	{
		Shavit_PrintToChat(client, "Replays are not available on this server.");
		return Plugin_Handled;
	}

	if(target < 1 || !Shavit_IsReplayEntity(target))
	{
		Shavit_PrintToChat(client, "Spectate a replay to check what it was run with.");
		return Plugin_Handled;
	}

	if(!gB_BotMarksTracked[target])
	{
		Shavit_PrintToChat(client, "Landfix: %snot recorded\x07ffffff for this run.", C_RED);
		Shavit_PrintToChat(client, "It was set before landfix started being recorded, or on another server.");
		return Plugin_Handled;
	}

	char label[32];
	ArrayList states = gA_BotStates[target];
	int changes = (states == null) ? 0 : states.Length;

	// No history is a run recorded between the marks arriving and the switches
	// being written down, so only the state it finished on is known.
	if(changes == 0)
	{
		LandfixStateLabel(gB_BotMarksEnabled[target], gI_BotMarksMode[target], label, sizeof(label));
		Shavit_PrintToChat(client, "Landfix: %s\x07ffffff at the finish. No switch history for this run.", label);
		return Plugin_Handled;
	}

	bool started = (states.Get(0, 1) == 1);
	LandfixStateLabel(started, states.Get(0, 2), label, sizeof(label));

	if(changes == 1)
	{
		Shavit_PrintToChat(client, "Landfix: %s\x07ffffff for the whole run.", label);
		return Plugin_Handled;
	}

	Shavit_PrintToChat(client, "Landfix: started %s\x07ffffff, switched %d time%s during the run.",
		label, changes - 1, (changes == 2) ? "" : "s");

	for(int i = 1; i < changes; i++)
	{
		float when = states.Get(i, 0);
		LandfixStateLabel(states.Get(i, 1) == 1, states.Get(i, 2), label, sizeof(label));
		Shavit_PrintToChat(client, "  %.2f: %s", when, label);
	}

	return Plugin_Handled;
}


// Read back off disk rather than kept in memory from the run: the bot is usually
// playing a record set long before this map started, and often by somebody who has
// since left.
// A bot may be playing the map's own record, a run imported from another server
// with !wros, or an archived one. The marks that belong to it are found by asking
// which run it is holding rather than by guessing a path from the map name, which
// would describe an import with whatever sat beside the local record.
public Action Timer_LateLoadReplayBots(Handle timer)
{
	for(int client = 1; client <= MaxClients; client++)
	{
		if(g_bReplayPlayback && IsClientInGame(client) && IsFakeClient(client) && Shavit_IsReplayEntity(client))
			LoadBotLandfixMarks(client);
	}

	return Plugin_Stop;
}

void LoadBotLandfixMarks(int bot)
{
	ClearBotLandfixMarks(bot);

	if(bot < 1 || bot > MaxClients)
		return;

	if(!g_bReplayPlayback)
		return;

	gB_BotMarksKnown[bot] = true;

	frame_cache_t cache;
	Shavit_GetReplayBotCache(bot, cache);

	char folder[PLATFORM_MAX_PATH], map[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	Shavit_GetReplayFolderPath(folder, sizeof(folder));
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));

	int style = Shavit_GetReplayBotStyle(bot);
	int track = Shavit_GetReplayBotTrack(bot);

	// The record the map is holding, which is what a bot usually plays. Same name
	// shavit gives the file: the track is only in it past the main one.
	if(track > 0)
		FormatEx(path, sizeof(path), "%s/%d/%s_%d.replay.landfix", folder, style, map, track);
	else
		FormatEx(path, sizeof(path), "%s/%d/%s.replay.landfix", folder, style, map);

	if(ReadLandfixFile(bot, path, cache))
		return;

	// Otherwise an archived run. shavit-replay-history puts the account id in the
	// filename, so the folder is narrowed to that runner before anything is opened.
	char dir[PLATFORM_MAX_PATH], prefix[128];
	BuildPath(Path_SM, dir, sizeof(dir), "data/replay-history/%d", style);
	FormatEx(prefix, sizeof(prefix), "%s_t%d_a%d_", map, track, cache.iSteamID);

	DirectoryListing listing = OpenDirectory(dir);

	if(listing == null)
		return;

	char entry[PLATFORM_MAX_PATH];
	FileType type;

	while(listing.GetNext(entry, sizeof(entry), type))
	{
		if(type != FileType_File || StrContains(entry, prefix) != 0)
			continue;

		if(StrContains(entry, ".replay.landfix") == -1)
			continue;

		FormatEx(path, sizeof(path), "%s/%s", dir, entry);

		if(ReadLandfixFile(bot, path, cache))
			break;
	}

	delete listing;
}

// Reads one candidate and keeps it only if it says it belongs to this run. A file
// written before the identity was added carries neither, so it is refused: that
// guesswork is the thing this replaces.
bool ReadLandfixFile(int bot, const char[] path, frame_cache_t cache)
{
	File file = OpenFile(path, "r");

	if(file == null)
		return false;

	char line[64], field[4][24];
	ArrayList states = new ArrayList(3);
	bool enabled = false;
	int mode = 0, auth = 0;
	float time = -1.0;

	while(file.ReadLine(line, sizeof(line)))
	{
		int count = ExplodeString(line, " ", field, sizeof(field), sizeof(field[]));

		if(count >= 2 && StrEqual(field[0], "auth"))
			auth = StringToInt(field[1]);
		else if(count >= 2 && StrEqual(field[0], "time"))
			time = StringToFloat(field[1]);
		else if(count >= 2 && StrEqual(field[0], "enabled"))
			enabled = (StringToInt(field[1]) == 1);
		else if(count >= 2 && StrEqual(field[0], "mode"))
			mode = StringToInt(field[1]);
		else if(count >= 4 && StrEqual(field[0], "state"))
		{
			int index = states.Push(StringToFloat(field[1]));
			states.Set(index, StringToInt(field[2]), 1);
			states.Set(index, StringToInt(field[3]), 2);
		}
	}

	delete file;

	// Keyed on the run time. Shavit_GetReplayBotCache does not return a usable
	// iSteamID for a replay bot, and the path already pins map, style and track.
	if(auth == 0 || FloatAbs(time - cache.fTime) > LANDFIX_TIME_EPSILON)
	{
		delete states;
		return false;
	}

	gA_BotStates[bot] = states;
	gB_BotMarksEnabled[bot] = enabled;
	gI_BotMarksMode[bot] = mode;
	gB_BotMarksTracked[bot] = true;

	return true;
}

void ClearBotLandfixMarks(int bot)
{
	if(bot < 1 || bot > MaxClients)
		return;

	delete gA_BotStates[bot];
	gB_BotMarksKnown[bot] = false;
	gB_BotMarksTracked[bot] = false;
	gB_BotMarksEnabled[bot] = false;
	gI_BotMarksMode[bot] = 0;
}

public void Shavit_OnReplayStart(int ent, int type, bool delay_elapsed)
{
	LoadBotLandfixMarks(ent);
}

public void Shavit_OnReplayEnd(int ent, int type, bool actually_finished)
{
	ClearBotLandfixMarks(ent);
}

// Who a client is watching, or 0 when they are playing or in free look. Read off
// the observer target rather than Shavit_GetClientReplayBot, which answers for the
// bot racing a client and not for whoever they happen to be spectating.
int SpectatedTarget(int client)
{
	if(IsPlayerAlive(client))
		return 0;

	int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");

	if(target < 1 || target > MaxClients || target == client || !IsClientInGame(target))
		return 0;

	return target;
}

// How far into the run the bot is. The preframes are the approach before the timer
// started, which is what the marks are measured from.
float BotReplayRunTime(int bot)
{
	if(!g_bReplayPlayback)
		return 0.0;

	int frame = Shavit_GetReplayBotCurrentFrame(bot) - Shavit_GetReplayCachePreFrames(bot);

	return frame <= 0 ? 0.0 : float(frame) * GetTickInterval();
}

// The line a player sees for their own landfix, and the one a spectator reads off
// them. False means draw nothing, which is what the plugin does with landfix off.
bool FormatClientLandfixHud(int client, char[] buffer, int maxlen)
{
	if(!gB_PreferencesLoaded[client] || !gB_Enabled[client])
		return false;

	FormatEx(buffer, maxlen, "Landfix: %s", gB_LandfixType[client] ? "Haze" : "NoTimeLoss");

	return true;
}

// The same line for the replay being watched, taken at the point of the run on
// screen. A replay with no file beside it predates the marks and cannot be
// answered either way, so it draws nothing rather than guessing.
bool FormatBotLandfixHud(int bot, char[] buffer, int maxlen)
{
	if(!gB_BotMarksTracked[bot])
		return false;

	// Falls back to the state at the finish for a run recorded before the
	// switches were written down.
	bool on = gB_BotMarksEnabled[bot];
	int mode = gI_BotMarksMode[bot];
	ArrayList states = gA_BotStates[bot];
	int changes = (states == null) ? 0 : states.Length;
	float now = BotReplayRunTime(bot);

	for(int i = 0; i < changes; i++)
	{
		float when = states.Get(i, 0);

		if(when > now)
			break;

		on = (states.Get(i, 1) == 1);
		mode = states.Get(i, 2);
	}

	if(!on)
		return false;

	FormatEx(buffer, maxlen, "Landfix: %s", mode == 1 ? "Haze" : "NoTimeLoss");

	return true;
}

// Jump tracking -------------------------------------------------------------

// Takeoff and landing are read straight off FL_ONGROUND so they land on the
// exact tick the ground state changes.
void TrackGround(int client)
{
	if(!IsPlayerAlive(client))
		return;

	bool onGround = ((GetEntityFlags(client) & FL_ONGROUND) != 0);

	if(gB_WasOnGround[client] && !onGround)
		gI_LastTakeoffTick[client] = GetGameTickCount();
	else if(!gB_WasOnGround[client] && onGround)
		OnClientLanded(client);

	gB_WasOnGround[client] = onGround;
}


// Fires the moment the jump is made, for anything targeting the current jump.
public void Event_PlayerJump(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	int jumps = Shavit_GetClientJumps(client);
	CheckRunReset(client, jumps);

	if(gB_LandfixWindowActive[client] || !IsLandfixArmed(client))
		return;

	int end = 0;
	int kind = LookupLandfixJump(client, jumps, end);

	if(kind == 0)
		return;

	bool want = !gB_LandfixBaseState[client];
	bool flipped;

	if(!SetLandfixJumpState(client, want, flipped))
		return;

	OpenLandfixWindow(client, kind, jumps, end);

	if(flipped)
		NotifyLandfixJump(client, want, jumps, end);
}


// Closes anything that reached its end jump, then switches the next target on
// while the player is still on the ground.
void OnClientLanded(int client)
{
	if(GetGameTickCount() - gI_LastTakeoffTick[client] < LAND_GRACE_TICKS)
		return;

	int jumps = Shavit_GetClientJumps(client);
	CheckRunReset(client, jumps);

	int next = jumps + 1;

	bool armed = IsLandfixArmed(client);

	if(!gB_LandfixWindowActive[client] && !armed)
		return;

	bool expires = (
		gB_LandfixWindowActive[client]
		&&
		(
			gB_LandfixRangeActive[client]
			? jumps >= gI_LandfixRangeEndJump[client]
			: gI_LandfixOneShotEndJump[client] > 0
				&& jumps >= gI_LandfixOneShotEndJump[client]
		)
	);

	// Still in the middle of a range.
	if(gB_LandfixWindowActive[client] && !expires)
		return;

	int end = 0;
	int kind = armed
		? LookupLandfixJump(client, next, end)
		: 0;

	bool flipped;

	if(kind != 0)
	{
		bool want = !gB_LandfixBaseState[client];

		if(!SetLandfixJumpState(client, want, flipped))
			return;

		OpenLandfixWindow(client, kind, next, end);

		if(flipped)
			NotifyLandfixJump(client, want, next, end);
	}
	else if(gB_LandfixWindowActive[client])
	{
		bool base = gB_LandfixBaseState[client];

		if(!SetLandfixJumpState(client, base, flipped))
			return;

		CloseLandfixWindow(client);

		if(flipped)
			NotifyLandfixJump(client, base, 0, 0);
	}
}


// State ---------------------------------------------------------------------

bool SetLandfixJumpState(int client, bool want, bool &flipped)
{
	flipped = false;

	if(gB_Enabled[client] == want)
		return true;

	int tick = GetGameTickCount();

	if(tick - gI_LandfixLastToggleTick[client] < TOGGLE_COOLDOWN_TICKS)
		return false;

	gI_LandfixLastToggleTick[client] = tick;

	// Temporary jump toggles must never save the user's normal Landfix
	// preference.
	SetLandfixEnabled(client, want, false);
	PrintLandfixState(client);

	flipped = true;

	return true;
}


// Shavit resets the jump count when a run restarts.
void CheckRunReset(int client, int jumps)
{
	if(jumps < gI_LastJumps[client])
		ResetLandfixJumps(client);

	gI_LastJumps[client] = jumps;
}

void ResetLandfixJumps(int client)
{
	if(gB_LandfixWindowActive[client])
	{
		bool flipped;

		gI_LandfixLastToggleTick[client] = 0;

		SetLandfixJumpState(
			client,
			gB_LandfixBaseState[client],
			flipped
		);

		if(flipped)
			NotifyLandfixJump(
				client,
				gB_LandfixBaseState[client],
				0,
				0
			);
	}

	CloseLandfixWindow(client);

	// Whatever Landfix is set to now is the state this run starts from.
	gB_LandfixBaseState[client] = gB_Enabled[client];

	gI_LastJumps[client] = 0;
}


// Window handling -----------------------------------------------------------

void OpenLandfixWindow(int client, int kind, int jump, int end)
{
	gB_LandfixWindowActive[client] = true;
	gB_LandfixRangeActive[client] = (kind == 1);

	gI_LandfixRangeEndJump[client] = (kind == 1) ? end : 0;
	gI_LandfixOneShotEndJump[client] = (kind == 1) ? 0 : jump;
}

void CloseLandfixWindow(int client)
{
	gB_LandfixWindowActive[client] = false;
	gB_LandfixRangeActive[client] = false;

	gI_LandfixRangeEndJump[client] = 0;
	gI_LandfixOneShotEndJump[client] = 0;
}


// Notifications ------------------------------------------------------------

void NotifyLandfixJump(int client, bool on, int jump, int end)
{
	if(!gCV_ToggleHints.BoolValue)
		return;

	if(jump <= 0)
	{
		PrintHintText(
			client,
			"Landfix: %s",
			on ? "ON" : "OFF"
		);
	}
	else if(end > jump)
	{
		PrintHintText(
			client,
			"Landfix: %s (J%d-%d)",
			on ? "ON" : "OFF",
			jump,
			end
		);
	}
	else
	{
		PrintHintText(
			client,
			"Landfix: %s (J%d)",
			on ? "ON" : "OFF",
			jump
		);
	}
}


// Target list --------------------------------------------------------------

bool IsLandfixArmed(int client)
{
	return (
		gB_LandfixJumpsEnabled[client]
		&&
		gA_LandfixTargets[client] != null
		&&
		gA_LandfixTargets[client].Length > 0
	);
}

// 0 = not a target
// 1 = starts a range
// 2 = single jump
int LookupLandfixJump(int client, int jump, int &endOut)
{
	endOut = 0;

	ArrayList list = gA_LandfixTargets[client];

	if(list == null)
		return 0;

	Target t;

	for(int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, t, sizeof(t));

		if(t.start != jump)
			continue;

		if(t.kind == 1)
		{
			endOut = t.end;
			return 1;
		}

		return 2;
	}

	return 0;
}

bool AddLandfixTarget(int client, int kind, int start, int end)
{
	if(gA_LandfixTargets[client] == null)
		gA_LandfixTargets[client] = new ArrayList(sizeof(Target));

	ArrayList list = gA_LandfixTargets[client];

	Target existing;

	for(int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, existing, sizeof(existing));

		if(
			existing.kind == kind
			&& existing.start == start
			&& existing.end == end
		)
		{
			return false;
		}
	}

	Target t;
	t.kind = kind;
	t.start = start;
	t.end = end;

	list.PushArray(t, sizeof(t));

	return true;
}

int AddLandfixTargetsFromString(int client, const char[] input)
{
	char buffer[256];
	strcopy(buffer, sizeof(buffer), input);

	ReplaceString(buffer, sizeof(buffer), ",", " ");

	char parts[32][16];
	int count = ExplodeString(
		buffer,
		" ",
		parts,
		sizeof(parts),
		sizeof(parts[])
	);

	int added = 0;

	for(int i = 0; i < count; i++)
	{
		TrimString(parts[i]);

		if(parts[i][0] == '\0')
			continue;

		int dash = StrContains(parts[i], "-");

		if(dash > 0)
		{
			char low[16];
			strcopy(low, sizeof(low), parts[i]);
			low[dash] = '\0';

			int start = StringToInt(low);
			int end = StringToInt(parts[i][dash + 1]);

			if(
				start > 0
				&& end > start
				&& AddLandfixTarget(client, 1, start, end)
			)
			{
				added++;
			}
		}
		else
		{
			int jump = StringToInt(parts[i]);

			if(
				jump > 0
				&& AddLandfixTarget(client, 0, jump, jump)
			)
			{
				added++;
			}
		}
	}

	return added;
}

void ClearLandfixTargets(int client)
{
	if(gA_LandfixTargets[client] != null)
		gA_LandfixTargets[client].Clear();
}

int TargetCount(int client)
{
	return (
		gA_LandfixTargets[client] == null
		? 0
		: gA_LandfixTargets[client].Length
	);
}

void BuildLandfixList(int client, char[] out, int maxlen)
{
	out[0] = '\0';

	ArrayList list = gA_LandfixTargets[client];

	if(list == null || list.Length == 0)
		return;

	Target t;
	char piece[24];

	for(int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, t, sizeof(t));

		if(t.kind == 1)
			Format(piece, sizeof(piece), "%d-%d", t.start, t.end);
		else
			Format(piece, sizeof(piece), "%d", t.start);

		if(out[0] == '\0')
			strcopy(out, maxlen, piece);
		else
			Format(out, maxlen, "%s,%s", out, piece);
	}
}

void PrintLandfixJumpStatus(int client)
{
	int oneShots = 0;
	int ranges = 0;

	ArrayList list = gA_LandfixTargets[client];

	if(list != null)
	{
		Target t;

		for(int i = 0; i < list.Length; i++)
		{
			list.GetArray(i, t, sizeof(t));

			if(t.kind == 1)
				ranges++;
			else
				oneShots++;
		}
	}

	int end = gB_LandfixRangeActive[client]
		? gI_LandfixRangeEndJump[client]
		: gI_LandfixOneShotEndJump[client];

	Shavit_PrintToChat(
		client,
		"Landfix: enabled=%d base=%d now=%d items=%d (one-shots=%d ranges=%d) jumps=%d activeRange=%d end=%d",
		gB_LandfixJumpsEnabled[client] ? 1 : 0,
		gB_LandfixBaseState[client] ? 1 : 0,
		gB_Enabled[client] ? 1 : 0,
		TargetCount(client),
		oneShots,
		ranges,
		Shavit_GetClientJumps(client),
		gB_LandfixRangeActive[client] ? 1 : 0,
		end
	);
}

// Landfix Toggle Database ----------------------------------------------------

void ConnectLandfixDatabase()
{
	char databaseName[64];
	gCV_LandfixDatabase.GetString(databaseName, sizeof(databaseName));
	Database.Connect(SQL_OnLandfixDatabaseConnected, databaseName);
}

public void SQL_OnLandfixDatabaseConnected(Database db, const char[] error, any data)
{
	if(db == null)
	{
		LogError("superlandfix database connection failed: %s", error);
		return;
	}

	gH_LandfixDB = db;

	char driver[32];
	db.Driver.GetIdentifier(driver, sizeof(driver));

	char query[512];
	if(StrEqual(driver, "sqlite", false))
	{
		FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS landfix_toggles (steamid TEXT NOT NULL, map TEXT NOT NULL, enabled INTEGER NOT NULL, jumps TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (steamid, map))");
	}
	else
	{
		FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS landfix_toggles (steamid VARCHAR(64) NOT NULL, map VARCHAR(255) NOT NULL, enabled INT NOT NULL, jumps VARCHAR(300) NOT NULL, updated_at INT NOT NULL, PRIMARY KEY (steamid, map))");
	}

	db.Query(SQL_LandfixTogglesTableCallback, query);
}

public void SQL_LandfixTogglesTableCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("superlandfix landfix_toggles table creation failed: %s", error);
		return;
	}

	CreateLandfixPlayerTable();
}

void CreateLandfixPlayerTable()
{
	char driver[32];
	gH_LandfixDB.Driver.GetIdentifier(driver, sizeof(driver));

	char query[512];
	if(StrEqual(driver, "sqlite", false))
	{
		FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS landfix_players (steamid TEXT PRIMARY KEY, last_name TEXT NOT NULL, updated_at INTEGER NOT NULL)");
	}
	else
	{
		FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS landfix_players (steamid VARCHAR(64) NOT NULL PRIMARY KEY, last_name VARCHAR(128) NOT NULL, updated_at INT NOT NULL)");
	}

	gH_LandfixDB.Query(SQL_LandfixPlayerTableCallback, query);
}

public void SQL_LandfixPlayerTableCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("superlandfix landfix_players table creation failed: %s", error);
		return;
	}

	gB_LandfixDBReady = true;

	// Tables now exist, so pull in toggles for anyone already in game.
	for(int client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client) && AreClientCookiesCached(client))
		{
			RememberLandfixProfile(client);
			RequestLandfixToggleLoad(client);
		}
	}
}

public void SQL_LandfixGenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
		LogError("superlandfix database query failed: %s", error);
}

// Shares the same validation as the settings handoff file.
bool GetLandfixSteamId(int client, char[] steamId, int maxlen)
{
	return GetLandfixHandoffAuthId(client, steamId, maxlen);
}

void RememberLandfixProfile(int client)
{
	if(!gB_LandfixDBReady || gH_LandfixDB == null || client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	char steamId[MAX_AUTHID_LENGTH];
	if(!GetLandfixSteamId(client, steamId, sizeof(steamId)))
		return;

	char name[MAX_NAME_LENGTH], escapedSteamId[MAX_AUTHID_LENGTH * 2 + 1], escapedName[MAX_NAME_LENGTH * 2 + 1];
	GetClientName(client, name, sizeof(name));
	gH_LandfixDB.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
	gH_LandfixDB.Escape(name, escapedName, sizeof(escapedName));

	char query[512];
	FormatEx(query, sizeof(query), "REPLACE INTO landfix_players (steamid, last_name, updated_at) VALUES ('%s', '%s', %d)", escapedSteamId, escapedName, GetTime());
	gH_LandfixDB.Query(SQL_LandfixGenericCallback, query);
}

// Called on connect and again on every map change, so toggles always match the current map.
void RequestLandfixToggleLoad(int client)
{
	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	// Defaults while the async load is outstanding, or if there's no saved row for this map.
	ClearLandfixTargets(client);
	gB_LandfixJumpsEnabled[client] = true;

	if(!gB_LandfixDBReady || gH_LandfixDB == null)
		return;

	char steamId[MAX_AUTHID_LENGTH];
	if(!GetLandfixSteamId(client, steamId, sizeof(steamId)))
		return;

	char escapedSteamId[MAX_AUTHID_LENGTH * 2 + 1], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
	gH_LandfixDB.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
	gH_LandfixDB.Escape(gS_LandfixMap, escapedMap, sizeof(escapedMap));

	char query[768];
	FormatEx(query, sizeof(query), "SELECT enabled, jumps FROM landfix_toggles WHERE steamid = '%s' AND map = '%s'", escapedSteamId, escapedMap);

	gI_LandfixLoadGen[client]++;

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(gI_LandfixLoadGen[client]);
	pack.WriteString(gS_LandfixMap);
	gH_LandfixDB.Query(SQL_LandfixToggleLoadCallback, query, pack);
}

public void SQL_LandfixToggleLoadCallback(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int userid = pack.ReadCell();
	int generation = pack.ReadCell();
	char map[PLATFORM_MAX_PATH];
	pack.ReadString(map, sizeof(map));
	delete pack;

	int client = GetClientOfUserId(userid);

	// Stale if the client left, a newer load superseded this one, or the map changed since.
	if(client <= 0 || generation != gI_LandfixLoadGen[client] || !StrEqual(map, gS_LandfixMap))
		return;

	if(results == null)
	{
		LogError("superlandfix toggle load failed: %s", error);
		return;
	}

	if(!results.FetchRow())
		return; // No saved toggles for this map; the defaults already applied.

	bool enabled = results.FetchInt(0) != 0;
	char jumps[256];
	results.FetchString(1, jumps, sizeof(jumps));

	ClearLandfixTargets(client);
	gB_LandfixJumpsEnabled[client] = enabled;
	AddLandfixTargetsFromString(client, jumps);
	ResetLandfixJumps(client);
}

void SaveLandfixToggles(int client)
{
	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if(!gB_LandfixDBReady || gH_LandfixDB == null)
		return;

	char steamId[MAX_AUTHID_LENGTH];
	if(!GetLandfixSteamId(client, steamId, sizeof(steamId)))
		return;

	char list[256];
	BuildLandfixList(client, list, sizeof(list));

	char escapedSteamId[MAX_AUTHID_LENGTH * 2 + 1], escapedMap[PLATFORM_MAX_PATH * 2 + 1], escapedList[512];
	gH_LandfixDB.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
	gH_LandfixDB.Escape(gS_LandfixMap, escapedMap, sizeof(escapedMap));
	gH_LandfixDB.Escape(list, escapedList, sizeof(escapedList));

	char query[900];
	FormatEx(query, sizeof(query), "REPLACE INTO landfix_toggles (steamid, map, enabled, jumps, updated_at) VALUES ('%s', '%s', %d, '%s', %d)",
		escapedSteamId, escapedMap, gB_LandfixJumpsEnabled[client] ? 1 : 0, escapedList, GetTime());
	gH_LandfixDB.Query(SQL_LandfixGenericCallback, query);
}

// Browsing other players' toggles ---------------------------------------

bool CanBrowseLandfixToggles(int client)
{
	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;

	if(!gB_LandfixDBReady || gH_LandfixDB == null)
	{
		Shavit_PrintToChat(client, "Landfix toggle browsing is still loading.");
		return false;
	}

	return true;
}

void ShowLandfixToggleBrowseMenu(int client)
{
	if(!CanBrowseLandfixToggles(client))
		return;

	char steamId[MAX_AUTHID_LENGTH];
	if(!GetLandfixSteamId(client, steamId, sizeof(steamId)))
		return;

	char escapedSteamId[MAX_AUTHID_LENGTH * 2 + 1], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
	gH_LandfixDB.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
	gH_LandfixDB.Escape(gS_LandfixMap, escapedMap, sizeof(escapedMap));

	char query[1024];
	FormatEx(query, sizeof(query),
		"SELECT DISTINCT t.steamid, COALESCE(p.last_name, t.steamid) FROM landfix_toggles t LEFT JOIN landfix_players p ON p.steamid = t.steamid WHERE t.map = '%s' AND t.steamid != '%s' ORDER BY 2 ASC LIMIT 128",
		escapedMap, escapedSteamId);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(gS_LandfixMap);
	gH_LandfixDB.Query(SQL_LandfixBrowseMenuCallback, query, pack);
}

public void SQL_LandfixBrowseMenuCallback(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int userid = pack.ReadCell();
	char map[PLATFORM_MAX_PATH];
	pack.ReadString(map, sizeof(map));
	delete pack;

	int client = GetClientOfUserId(userid);
	if(client <= 0 || !StrEqual(map, gS_LandfixMap))
		return;

	if(results == null)
	{
		LogError("superlandfix toggle browse query failed: %s", error);
		Shavit_PrintToChat(client, "Could not list saved Landfix toggles.");
		return;
	}

	Menu menu = new Menu(LandfixBrowseMenuHandler);
	menu.SetTitle("Landfix | Other Players' Toggles\n \n");

	int count = 0;
	while(results.FetchRow())
	{
		char ownerSteamId[MAX_AUTHID_LENGTH], ownerName[MAX_NAME_LENGTH];
		results.FetchString(0, ownerSteamId, sizeof(ownerSteamId));
		results.FetchString(1, ownerName, sizeof(ownerName));
		menu.AddItem(ownerSteamId, ownerName);
		count++;
	}

	if(count == 0)
		menu.AddItem("", "No saved Landfix toggles on this map", ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int LandfixBrowseMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if(action == MenuAction_Select)
	{
		char steamId[MAX_AUTHID_LENGTH];
		menu.GetItem(item, steamId, sizeof(steamId));
		LoadLandfixToggleProfile(client, steamId);
	}
	else if(action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowToggleMenu(client);
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

void LoadLandfixToggleProfile(int client, const char[] steamId)
{
	if(!CanBrowseLandfixToggles(client) || steamId[0] == '\0')
		return;

	char escapedSteamId[MAX_AUTHID_LENGTH * 2 + 1], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
	gH_LandfixDB.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
	gH_LandfixDB.Escape(gS_LandfixMap, escapedMap, sizeof(escapedMap));

	char query[768];
	FormatEx(query, sizeof(query), "SELECT enabled, jumps FROM landfix_toggles WHERE steamid = '%s' AND map = '%s'", escapedSteamId, escapedMap);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(gS_LandfixMap);
	gH_LandfixDB.Query(SQL_LandfixLoadProfileCallback, query, pack);
}

public void SQL_LandfixLoadProfileCallback(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int userid = pack.ReadCell();
	char map[PLATFORM_MAX_PATH];
	pack.ReadString(map, sizeof(map));
	delete pack;

	int client = GetClientOfUserId(userid);
	if(client <= 0 || !StrEqual(map, gS_LandfixMap))
		return;

	if(results == null)
	{
		LogError("superlandfix toggle profile load failed: %s", error);
		Shavit_PrintToChat(client, "Could not load that player's Landfix toggles.");
		return;
	}

	if(!results.FetchRow())
	{
		Shavit_PrintToChat(client, "That player has no saved Landfix toggles on this map.");
		ShowToggleMenu(client);
		return;
	}

	bool enabled = results.FetchInt(0) != 0;
	char jumps[256];
	results.FetchString(1, jumps, sizeof(jumps));

	ClearLandfixTargets(client);
	gB_LandfixJumpsEnabled[client] = enabled;
	AddLandfixTargetsFromString(client, jumps);
	ResetLandfixJumps(client);
	SaveLandfixToggles(client);

	char list[256];
	BuildLandfixList(client, list, sizeof(list));

	Shavit_PrintToChat(
		client,
		"Loaded Landfix toggles: %s%s",
		gS_Warning,
		list[0] != '\0' ? list : "(none)"
	);

	ShowToggleMenu(client);
}