-- UE 5.7 GNatives signature (community, UE4SS issue #1228)
-- Pattern is inside UObject::SkipFunction; a nearby lea r13 loads GNatives
function Register()
    return "4C 89 63 38 4C 89 63 40 8B 46 38 48 0F BA E0 08 73 05 4D 8B C4 EB 07 4C 63 46 44 4C 03 C7"
end

function OnMatchFound(MatchAddress)
    local LeaInstr = MatchAddress - 0x15
    local NextInstr = LeaInstr + 0x7
    local Offset = LeaInstr + 0x3
    local AddressLoaded = NextInstr + DerefToInt32(Offset)
    return AddressLoaded
end
