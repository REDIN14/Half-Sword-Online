-- FText::FText(FString&&) signature for Half Sword (UE5.4)
-- This file provides a custom AOB pattern for the FText constructor
-- The function may not be needed for basic Lua functionality

-- Return empty to signal that FText is not required for this game
-- UE4SS will continue without FText support if this returns nil

-- If you need FText support, find the actual AOB in IDA and provide it here:
-- return {
--     { pattern = "?? ?? ?? ?? ?? ?? ?? ??", offset = 0 }
-- }

-- For now, we'll provide a dummy that allows UE4SS to skip this scan
-- by returning an empty table (signals no match needed)
return nil
