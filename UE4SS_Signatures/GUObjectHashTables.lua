-- UE 5.7 FUObjectHashTables::Get() signature (community, UE4SS issue #1228)
function Register()
    return "40 53 48 83 EC 30 48 8B D9 8B C2 99 0F B7 D2 03"
end

function OnMatchFound(MatchAddress)
    local v1 = 0x100
    return MatchAddress + v1
end
