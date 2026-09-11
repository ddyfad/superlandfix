# SuperLandfix

Unified Landfix (NoTimeLoss/Haze) plugin with a customisable HUD, cookies,
per-jump toggles, and landfix marks recorded alongside shavit replays.

## Commands
/lf - Toggle Landfix (On/Off)    
/lfs - Toggle Landfix Mode (NoTimeLoss/Haze)    

/lfh - Toggle Landfix Hud (On/Off)      
/lfhc <number> - Set Hud Color (0-5)    

/lfm - Open Landfix Main Menu    
/lfi - Open Landfix Commands Menu   
/lfa - Open Landfix About Menu    

/lfc - Shows what landfix the replay you are spectating was run with    

## Landfix Toggle
Allows you to set certain jumps to toggle landfix, it uses the mode your landfix is currently set to.    
/lft - Brings up the landfixtoggle menu.      
/lft <# jump> - Enables landfix for the desired jump.      
/lft <# jump - #jump> - Enables landfix for the selected jumps.    

## Replay marks
Every run writes a `.replay.landfix` file beside the replay recording where
landfix moved the player and whether it was on or off, so a spectator can see
what a run was set to rather than their own setting.

## Credit
This is a continuation of [tadehack/landfix_wHudAndCookies](https://github.com/tadehack/landfix_wHudAndCookies),
started fresh without the old history. All prior work and credit belongs to its
authors.

Standalone Landfix plugins utilized:    
https://github.com/KawaiiClan/landfix (Olivia/NoTimeLoss)    
https://github.com/Haze1337/Landfix (Haze)    

Landfix Type idea and base code from:    
https://github.com/enimmy/not-broken-landfix    

Special thanks to lukah for most of the hud color system and menus and nora for implementing additional features and fixing some handle errors.   
