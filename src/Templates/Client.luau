return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent

local function StepReplication()
    if SendCursor <= 0 then
        return
    end

    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    Reliable:FireServer(Buffer, SendInstances)

    --> Keep the grown buffer around so the next frame doesn't have to regrow it
    SendCursor = 0
    SendOffset = 0
    table.clear(SendInstances)
end

--> Shared unreliable Fire body, every event reuses this instead of emitting its own copy
local function UnreliableFire(Write: (...any) -> ())
    return function(...)
        DetachScratch()
        Save(Stash)
        LoadScratch()
        Write(...)
        local Buffer = buffer.create(SendCursor)
        buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
        Unreliable:FireServer(Buffer, SendInstances)
        Load(Stash)
    end
end
]]
