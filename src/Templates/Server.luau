return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
if not Reliable then
    local RemoteEvent = Instance.new("RemoteEvent")
    RemoteEvent.Name = BASE_EVENT_NAME .. "_RELIABLE_REMOTE"
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
end

local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
if not Unreliable then
    local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
    UnreliableRemoteEvent.Name = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE"
    UnreliableRemoteEvent.Parent = ReplicatedStorage
    Unreliable = UnreliableRemoteEvent
end

local PlayersMap: {[Player]: BufferSave} = {}

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
end)

local function StepReplication()
    for Player, Send in PlayersMap do
        if Send.Cursor <= 0 then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        Reliable:FireClient(Player, Buffer, Send.Instances)

        --> Keep the grown buffer around so the next frame doesn't have to regrow it
        Send.Cursor = 0
        table.clear(Send.Instances)
    end
end

--> Appends an already serialized packet to a player's reliable send buffer
local function Append(Player: Player, Buffer: buffer, Size: number, Instances: {Instance})
    local Send = PlayersMap[Player]
    if not Send then
        Send = {
            Size = 64,
            Cursor = 0,
            Buffer = buffer.create(64),
            Instances = {}
        }
        PlayersMap[Player] = Send
    end

    local Cursor = Send.Cursor
    local InUse = Cursor + Size
    if InUse > Send.Size then
        local NewSize = Send.Size
        while InUse > NewSize do
            NewSize *= 1.5
        end

        local NewBuffer = buffer.create(NewSize)
        buffer.copy(NewBuffer, 0, Send.Buffer, 0, Cursor)
        Send.Size = NewSize
        Send.Buffer = NewBuffer
    end

    buffer.copy(Send.Buffer, Cursor, Buffer, 0, Size)
    Send.Cursor = InUse

    local Count = #Instances
    if Count > 0 then
        local Target = Send.Instances
        table.move(Instances, 1, Count, #Target + 1, Target)
    end
end
]]
