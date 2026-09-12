# SuperLandfix

Unified Landfix (NoTimeLoss/Haze) plugin with a customisable HUD, cookies and
per-jump toggles. Landfix is tracked per run, so while spectating you see what
the player or replay you are watching is using rather than your own setting.

## Requirements
Requires shavit (`shavit/core`).

shavit's `replay-recorder` and `replay-playback` are optional. Without them the
plugin still loads and landfix, the HUD, cookies and jump toggles all work as
normal - only the replay half is unavailable: no `.replay.landfix` files are
written, and `/lfc` reports that replays are not available. Spectating a live
player still shows their landfix, since that never needed the replay plugins.

## Commands
/lf - Toggle Landfix (On/Off)    
/lfs - Toggle Landfix Mode (NoTimeLoss/Haze)    

/lfh - Toggle Landfix Hud (On/Off)      
/lfhc <number> - Set Hud Color (0-5)    

/lfm - Open Landfix Main Menu    
/lfi - Open Landfix Commands Menu   
/lfa - Open Landfix About Menu    

/lfc - Shows what landfix the replay you are spectating was run with (needs shavit replay)    

## Landfix Toggle
Allows you to set certain jumps to toggle landfix, it uses the mode your landfix is currently set to.    
/lft - Brings up the landfixtoggle menu.      
/lft <# jump> - Enables landfix for the desired jump.      
/lft <# jump - #jump> - Enables landfix for the selected jumps.    

## Landfix tracking
Landfix is tracked per run rather than per player, so the HUD follows whoever you
are watching instead of your own setting. Spectate a player and it shows the
landfix they are using; spectate a replay and it shows what that run was set to,
including when it was switched on or off partway through. `/lfc` prints the same
for the replay you are spectating.

*Note that only replays set after swapping to this plugin will have landfix data.*

This works because every run writes a `.replay.landfix` file beside the replay
recording, holding where landfix moved the player and its on/off history, so a
run can be read back long after it was set.

## Credit
This is a continuation of [tadehack/landfix_wHudAndCookies](https://github.com/tadehack/landfix_wHudAndCookies),
started fresh without the old history. All prior work and credit belongs to its
authors.

Standalone Landfix plugins utilized:    
https://github.com/KawaiiClan/landfix (Olivia/NoTimeLoss)    
https://github.com/Haze1337/Landfix (Haze)    

Landfix Type idea and base code from:    
https://github.com/enimmy/not-broken-landfix    

Special thanks to lukah for most of the hud color system and menus, nora for implementing additional features and fixing some handle errors and tommy/woolen for the landfixtoggle idea!  
