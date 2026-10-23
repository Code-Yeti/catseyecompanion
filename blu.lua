--[[
* Read-only subset of blusets' Blue Mage helper (blusets/blu.lua by atom0s, Ashita Development Team, GPLv3).
* Only the memory READS are kept: current set spells and BLU points. Everything that builds or sends packets
* (set/reset spells, equipex) is removed on purpose, so this stays an information-only addon.
*
* Ashita is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
* later version. See https://www.gnu.org/licenses/.
--]]

require('common');
local ffi = require('ffi');

local blu = T{
    offset = ffi.cast('uint32_t*', ashita.memory.find('FFXiMain.dll', 0, 'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0)),
    points = ffi.cast('uint8_t***', ashita.memory.find('FFXiMain.dll', 0, 'A1????????33C98A4E5E33D28A565D5F5E8950148948185B83C414C20400', 1, 0)),
};

function blu.is_blu_main() return AshitaCore:GetMemoryManager():GetPlayer():GetMainJob() == 16; end
function blu.is_blu_sub()  return AshitaCore:GetMemoryManager():GetPlayer():GetSubJob() == 16; end

function blu.get_spent_points() return blu.points[0][0][0x14]; end
function blu.get_max_points()   return blu.points[0][0][0x18]; end

-- The 20 set-spell slots: each byte is (spell id - 512), 0 = empty.
function blu.get_spells()
    local ptr = ashita.memory.read_uint32(AshitaCore:GetPointerManager():Get('inventory'));
    if (ptr == 0) then return T{}; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return T{}; end
    return T(ashita.memory.read_array((ptr + blu.offset[0]) + (blu.is_blu_main() and 0x04 or 0xA0), 0x14));
end

return blu;
