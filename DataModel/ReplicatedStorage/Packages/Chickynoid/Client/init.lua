--[=[
    @class ChickynoidClient
    @client

    Client namespace for the Chickynoid package.
]=]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ClientChickynoid = require(script.ClientChickynoid)
local CharacterModel = require(script.CharacterModel)

local DefaultConfigs = require(script.Parent.DefaultConfigs)
local Types = require(script.Parent.Types)
local TableUtil = require(script.Parent.Vendor.TableUtil)

local Enums = require(script.Parent.Enums)
local EventType = Enums.EventType

local ChickynoidClient = {}
ChickynoidClient.localChickynoid = nil
ChickynoidClient.snapshots = {}
ChickynoidClient.estimatedServerTime = 0
ChickynoidClient.estimatedServerTimeOffset = 0
ChickynoidClient.validServerTime = false
ChickynoidClient.startTime = tick()

ChickynoidClient.characters = {}
ChickynoidClient.localFrame = 0
ChickynoidClient.worldState = nil

--The local character
ChickynoidClient.characterModel = nil

--Milliseconds of *extra* buffer time to account for ping flux
ChickynoidClient.interpolationBuffer = 10 



local ClientConfig = TableUtil.Copy(DefaultConfigs.DefaultClientConfig, true)

function ChickynoidClient:SetConfig(config: Types.IClientConfig)
    local newConfig = TableUtil.Reconcile(config, DefaultConfigs.DefaultClientConfig)
    ClientConfig = newConfig
    print("Set client config to:", ClientConfig)
end

--[=[
    Setup default connections for the client-side Chickynoid. This mostly
    includes handling character spawns/despawns, for both the local player
    and other players.

    Everything done:
    - Listen for our own character spawn event and construct a LocalChickynoid
    class.
    - TODO

    @error "Remote cannot be found" -- Thrown when the client cannot find a remote after waiting for it for some period of time.
    @yields
]=]
function ChickynoidClient:Setup()
    
    
    local eventHandler = {}
    eventHandler[EventType.ChickynoidAdded] = function(event)
        local position = event.position
        print("Chickynoid spawned at", position)

        if (self.localChickynoid == nil) then
            self.localChickynoid = ClientChickynoid.new(position, ClientConfig)
        end
        --Force the position
        self.localChickynoid.simulation.state.pos = position
        
            
        
    end
    
    -- EventType.State
    eventHandler[EventType.State] = function(event)
        
        if self.localChickynoid and event.lastConfirmed then
            self.localChickynoid:HandleNewState(event.state, event.lastConfirmed)
        end
    end
    
    
    -- EventType.WorldState
    eventHandler[EventType.WorldState] = function(event)
        print("Got worldstate")
        --This would be a good time to run the collision setup
        self.worldState = event.worldState    
    end
        
    -- EventType.Snapshot
    eventHandler[EventType.Snapshot] = function(event)
        
 
        --Todo: correct this over time
        if (true) then   
            
            self:SetupTime(event.serverTime)
           -- print("Retime!")
            --self.estimatedServerTime = event.t
        end
            
        table.insert(self.snapshots, event)
        
        --we need like 2 or 3..
        if (#self.snapshots > 10) then
            table.remove(self.snapshots,1)
        end        
        
    end
    
    

    
    script.Parent.RemoteEvent.OnClientEvent:Connect(function(event)
        local func = eventHandler[event.t]
        if (func~=nil) then
            func(event)
        end
    end)
    
    --ALL OF THE CODE IN HERE IS ASTONISHINGLY TEMPORARY!
    
    RunService.Heartbeat:Connect(function(dt)
        
        
        if (self.worldState == nil) then
            --Waiting for worldstate
            return
        end
        --Have we at least tried to figure out the server time?        
        if (self.validServerTime == false) then
            return
        end
        
        --Do a new frame!!        
        self.localFrame += 1
        
        --Step the chickynoid
        if (self.localChickynoid) then
            self.localChickynoid:Heartbeat(dt)
            
            
            if (self.characterModel == nil) then
                self.characterModel = CharacterModel.new()
                self.characterModel:CreateModel()
            end
            
            self.characterModel:Think(dt, self.localChickynoid.simulation.characterData.serialized)
            
            -- Bind the camera
            local camera = game.Workspace.CurrentCamera
            camera.CameraSubject = self.characterModel.model
            camera.CameraType = Enum.CameraType.Custom
        end
        
        --Start building the world view, based on us having enoug snapshots to do so
        self.estimatedServerTime = self:LocalTick() - self.estimatedServerTimeOffset 
   
        --Calc the SERVER point in time to render out
        --Because we need to be between two snapshots, the minimum search time is "timeBetweenFrames"
        --But because there might be network flux, we add some extra buffer too
        local timeBetweenServerFrames = (1 / self.worldState.serverHz)
        local searchPad = math.clamp(self.interpolationBuffer,0,500) * 0.001
        local pointInTimeToRender = self.estimatedServerTime - (timeBetweenServerFrames + searchPad)
       
        local last = nil
        local prev = self.snapshots[1]
        for key,value in pairs(self.snapshots) do
            
            if (value.serverTime > pointInTimeToRender) then
                last = value
                break
            end
            prev = value
        end
        
        if (prev and last and prev ~= last) then
            
            --So pointInTimeToRender is between prev.t and last.t
            local frac = (pointInTimeToRender-prev.serverTime) / timeBetweenServerFrames
            
            for userId,lastData in pairs(last.charData) do
                
                local prevData = prev.charData[userId]
                
                if (prevData == nil) then
                    continue
                end
                
                local dataRecord = self.localChickynoid.simulation.characterData:Interpolate(prevData, lastData, frac)
                local character = self.characters[userId]
                
                --Add the character
                if (character == nil) then
                    
                    local record = {}
                    record.characterModel = CharacterModel.new()
                    record.characterModel:CreateModel()
                    
                    character = record
                    self.characters[userId] = record
                end
                
                character.frame = self.localFrame
                
                --Update it
                character.characterModel:Think(dt, dataRecord)
            end
            
            --Remove any characters who were not in this snapshot
            for key,value in pairs(self.characters) do
                if value.frame ~= self.localFrame then
                    value.characterModel:DestroyModel()
                    value.characterModel = nil
                    
                    self.characters[key] = nil
                end
            end
                
        end

    end)
end

--Use this instead of raw tick()
function ChickynoidClient:LocalTick()
    return tick() - self.startTime
end


-- This tries to figure out a correct delta for the server time
-- Better to update this infrequently as it will cause a "pop" in prediction
-- Thought: Replace with roblox solution or converging solution?
function ChickynoidClient:SetupTime(serverActualTime)
    
    local oldDelta = self.estimatedServerTimeOffset
    local newDelta = self:LocalTick() - serverActualTime
    self.validServerTime = true
    
    local delta = oldDelta - newDelta
    if (math.abs(delta * 1000) > 50) then --50ms out? try again
        self.estimatedServerTimeOffset = newDelta
    end
end

return ChickynoidClient
