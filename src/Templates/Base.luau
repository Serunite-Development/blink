return [[local Invocations = 0

local SendSize = 64
local SendOffset = 0
local SendCursor = 0
local SendBuffer = buffer.create(64)
local SendInstances = {}

local RecieveCursor = 0
local RecieveBuffer = buffer.create(64)

local RecieveInstances = {}
local RecieveInstanceCursor = 0

local Null = newproxy()

type Entry = {
    value: any,
    next: Entry?
}

type Queue = {
    head: Entry?,
    tail: Entry?
}

type BufferSave = {
    Size: number, 
    Cursor: number, 
    Buffer: buffer, 
    Instances: {Instance}
}

local function Read(Bytes: number)
    local Offset = RecieveCursor
    RecieveCursor += Bytes
    return Offset
end

--> Reusable send state for one-shot writes (FireAll/FireList/FireExcept, unreliables, exports)
--> so they don't allocate a fresh buffer and instance table on every call.
local ScratchBuffer = buffer.create(64)
local ScratchInstances = {}

--> Single reusable slot for Save/Load round-trips, these are never nested.
local Stash: BufferSave = {
    Size = 0,
    Cursor = 0,
    Buffer = ScratchBuffer,
    Instances = ScratchInstances
}

local function Save(Into: BufferSave?): BufferSave
    if Into then
        Into.Size = SendSize
        Into.Cursor = SendCursor
        Into.Buffer = SendBuffer
        Into.Instances = SendInstances
        return Into
    end

    return {
        Size = SendSize,
        Cursor = SendCursor,
        Buffer = SendBuffer,
        Instances = SendInstances
    }
end

local function Load(Save: BufferSave?)
    if Save then
        SendSize = Save.Size
        SendCursor = Save.Cursor
        SendOffset = Save.Cursor
        SendBuffer = Save.Buffer
        SendInstances = Save.Instances
        return
    end

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = buffer.create(64)
    SendInstances = {}
end

local function LoadScratch()
    SendSize = buffer.len(ScratchBuffer)
    SendCursor = 0
    SendOffset = 0
    SendBuffer = ScratchBuffer
    table.clear(ScratchInstances)
    SendInstances = ScratchInstances
end

local function Invoke()
    if Invocations == 255 then
        Invocations = 0
    end

    local Invocation = Invocations
    Invocations += 1
    return Invocation
end

local function Allocate(Bytes: number)
    local InUse = (SendCursor + Bytes)
    if InUse > SendSize then
        --> Avoid resizing the buffer for every write
        while InUse > SendSize do
            SendSize *= 1.5
        end

        local Buffer = buffer.create(SendSize)
        buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
        if SendBuffer == ScratchBuffer then
            ScratchBuffer = Buffer
        end
        SendBuffer = Buffer
    end

    SendOffset = SendCursor
    SendCursor += Bytes
    
    return SendOffset
end

local function CreateQueue(): Queue
    return {
        head = nil,
        tail = nil
    }
end

local function Pop(queue: Queue): any
    local head = queue.head
    if head == nil then
        return
    end

    queue.head = head.next
    return head.value
end

local function Push(queue: Queue, value: any)
    local entry: Entry = {
        value = value,
        next = nil
    }

    if queue.tail ~= nil then
        queue.tail.next = entry
    end

    queue.tail = entry

    if queue.head == nil then
        queue.head = entry
    end
end

local Calls = table.create(256)

local Events: any = {
    Reliable = {},
    Unreliable = {}
}

local Queue: any = {
    Reliable = {},
    Unreliable = {}
}

]]
