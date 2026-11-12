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

type PlayerSend = {
    Size: number,
    Cursor: number,
    Buffer: buffer,
    Instances: {Instance},
    --> Range of the shared broadcast buffer this player still has to receive, in bytes and instances
    BroadcastStart: number,
    BroadcastEnd: number,
    InstancesStart: number,
    InstancesEnd: number,
    --> Instances that belong to completed writes, anything past this was left by a write that errored
    InstanceCount: number
}

local PlayersMap: {[Player]: PlayerSend} = {}

--> Reliable FireAll packets are written once into a shared broadcast buffer instead of being copied into every
--> player's buffer. Each player tracks the range they're owed and only copies it into their own buffer when
--> something is sent to them individually (to keep ordering), players that only got broadcasts share one packet.
local BroadcastBuffer = buffer.create(64)
local BroadcastSize = 64
local BroadcastCursor = 0
local BroadcastInstances: {Instance} = {}
local BroadcastInstanceCount = 0

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
end)

local function GetSend(Player: Player): PlayerSend
    local Send = PlayersMap[Player]
    if not Send then
        Send = {
            Size = 64,
            Cursor = 0,
            Buffer = buffer.create(64),
            Instances = {},
            BroadcastStart = BroadcastCursor,
            BroadcastEnd = BroadcastCursor,
            InstancesStart = BroadcastInstanceCount,
            InstancesEnd = BroadcastInstanceCount,
            InstanceCount = 0
        }
        PlayersMap[Player] = Send
    end

    return Send
end

--> Drops instances a failed write pushed before erroring
local function Trim(Send: PlayerSend)
    local Instances = Send.Instances
    for Index = #Instances, Send.InstanceCount + 1, -1 do
        Instances[Index] = nil
    end
end

--> Marks everything currently in a player's send state as belonging to completed writes
local function Commit(Send: PlayerSend)
    Save(Send)
    Send.InstanceCount = #Send.Instances
end

--> Copies bytes and instances onto the end of a player's own send buffer
local function AppendTo(Send: PlayerSend, Buffer: buffer, Offset: number, Size: number, Instances: {Instance}, First: number, Last: number)
    Trim(Send)
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

    buffer.copy(Send.Buffer, Cursor, Buffer, Offset, Size)
    Send.Cursor = InUse

    if Last >= First then
        local Target = Send.Instances
        table.move(Instances, First, Last, #Target + 1, Target)
    end
    Send.InstanceCount = #Send.Instances
end

--> Moves the broadcasts a player is still owed into their own buffer, must run before anything is sent to them directly
local function CatchUp(Send: PlayerSend)
    local Start = Send.BroadcastStart
    local Size = Send.BroadcastEnd - Start
    if Size > 0 then
        AppendTo(Send, BroadcastBuffer, Start, Size, BroadcastInstances, Send.InstancesStart + 1, Send.InstancesEnd)
    end

    Send.BroadcastStart = BroadcastCursor
    Send.BroadcastEnd = BroadcastCursor
    Send.InstancesStart = BroadcastInstanceCount
    Send.InstancesEnd = BroadcastInstanceCount
end

--> Returns a player's send state ready for an individual write
local function Prepare(Player: Player): PlayerSend
    local Send = GetSend(Player)
    Trim(Send)
    if Send.BroadcastEnd > Send.BroadcastStart then
        CatchUp(Send)
    end
    return Send
end

local function DropUncommittedInstances()
    for Index = #BroadcastInstances, BroadcastInstanceCount + 1, -1 do
        BroadcastInstances[Index] = nil
    end
end

local function StepReplication()
    DropUncommittedInstances()

    local Shared: buffer? = nil
    for Player, Send in PlayersMap do
        --> Players that only received broadcasts this frame all get the same packet
        if Send.Cursor == 0 and Send.BroadcastStart == 0 and Send.BroadcastEnd == BroadcastCursor and BroadcastCursor > 0 then
            if not Shared then
                local Packet = buffer.create(BroadcastCursor)
                buffer.copy(Packet, 0, BroadcastBuffer, 0, BroadcastCursor)
                Shared = Packet
            end

            Reliable:FireClient(Player, Shared, BroadcastInstances)
        else
            Trim(Send)
            if Send.BroadcastEnd > Send.BroadcastStart then
                CatchUp(Send)
            end

            if Send.Cursor > 0 then
                local Buffer = buffer.create(Send.Cursor)
                buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
                Reliable:FireClient(Player, Buffer, Send.Instances)
            end
        end

        --> Keep the grown buffer around so the next frame doesn't have to regrow it
        Send.Cursor = 0
        Send.BroadcastStart = 0
        Send.BroadcastEnd = 0
        Send.InstancesStart = 0
        Send.InstancesEnd = 0
        Send.InstanceCount = 0
        table.clear(Send.Instances)
    end

    BroadcastCursor = 0
    BroadcastInstanceCount = 0
    table.clear(BroadcastInstances)
end

--> Appends an already serialized packet to a player's reliable send buffer
local function Append(Player: Player, Buffer: buffer, Size: number, Instances: {Instance})
    AppendTo(Prepare(Player), Buffer, 0, Size, Instances, 1, #Instances)
end

--> Shared Fire bodies, every event reuses these instead of emitting its own copies
local function ReliableFire(Write: (...any) -> ())
    return function(Player: Player, ...)
        local Send = Prepare(Player)
        Load(Send)
        Write(...)
        Commit(Send)
    end
end

--> Shared body of every reliable FireAll, kept out of the per-event closure so those stay small
local function Broadcast(Write: (...any) -> (), ...)
    --> Drop anything a previously errored write left past the committed end
    DropUncommittedInstances()

    local Start, InstancesStart = BroadcastCursor, BroadcastInstanceCount
    SendSize = BroadcastSize
    SendCursor = Start
    SendOffset = Start
    SendBuffer = BroadcastBuffer
    SendInstances = BroadcastInstances
    Write(...)

    --> Commit, only reached if the write didn't error
    BroadcastBuffer = SendBuffer
    BroadcastSize = SendSize
    BroadcastCursor = SendCursor
    BroadcastInstanceCount = #BroadcastInstances

    local End, InstancesEnd = BroadcastCursor, BroadcastInstanceCount
    for _, Player in Players:GetPlayers() do
        local Send = GetSend(Player)
        if Send.BroadcastEnd ~= Start then
            --> Not contiguous with what they're owed (they missed a broadcast), settle the old range first
            if Send.BroadcastEnd > Send.BroadcastStart then
                CatchUp(Send)
            end
            Send.BroadcastStart = Start
            Send.InstancesStart = InstancesStart
        end
        Send.BroadcastEnd = End
        Send.InstancesEnd = InstancesEnd
    end
end

local function ReliableFireAll(Write: (...any) -> ())
    return function(...)
        Broadcast(Write, ...)
    end
end

local function ReliableFireList(Write: (...any) -> ())
    return function(List: {Player}, ...)
        LoadScratch()
        Write(...)
        local Buffer, Size, Instances = SendBuffer, SendCursor, SendInstances
        for _, Player in List do
            Append(Player, Buffer, Size, Instances)
        end
    end
end

local function ReliableFireExcept(Write: (...any) -> ())
    return function(Except: Player, ...)
        LoadScratch()
        Write(...)
        local Buffer, Size, Instances = SendBuffer, SendCursor, SendInstances
        for _, Player in Players:GetPlayers() do
            if Player == Except then
                continue
            end
            Append(Player, Buffer, Size, Instances)
        end
    end
end

local function UnreliablePacket(): buffer
    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    return Buffer
end

local function UnreliableFire(Write: (...any) -> ())
    return function(Player: Player, ...)
        LoadScratch()
        Write(...)
        Unreliable:FireClient(Player, UnreliablePacket(), SendInstances)
    end
end

local function UnreliableFireAll(Write: (...any) -> ())
    return function(...)
        LoadScratch()
        Write(...)
        Unreliable:FireAllClients(UnreliablePacket(), SendInstances)
    end
end

local function UnreliableFireList(Write: (...any) -> ())
    return function(List: {Player}, ...)
        LoadScratch()
        Write(...)
        local Buffer = UnreliablePacket()
        for _, Player in List do
            Unreliable:FireClient(Player, Buffer, SendInstances)
        end
    end
end

local function UnreliableFireExcept(Write: (...any) -> ())
    return function(Except: Player, ...)
        LoadScratch()
        Write(...)
        local Buffer = UnreliablePacket()
        for _, Player in Players:GetPlayers() do
            if Player == Except then
                continue
            end
            Unreliable:FireClient(Player, Buffer, SendInstances)
        end
    end
end
]]
