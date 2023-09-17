--!strict
-- huge thanks to MrChickenRocket
-- much of the design is directly based on their work here https://gist.github.com/MrChickenRocket/19d21c1786503b3c8a7b685368db64de
local _Package = script
local _Packages = _Package.Parent

-- Services
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Maid = require(_Packages:WaitForChild("Maid"))
local ServiceProxy = require(_Packages:WaitForChild("ServiceProxy"))
local NetworkUtil = require(_Packages:WaitForChild("NetworkUtil"))

-- Modules
-- Types
type Maid = Maid.Maid
export type Trackable = Model | BasePart

type ClientRecordData = {
	Model: Model?,
	PrimaryPart: BasePart,
	Key: Trackable,
	Parts: {[number]: BasePart},
	CFrame: {
		Current: CFrame,
		Target: CFrame,
		Last: CFrame
	},
	Position: CFrame?,
	Rotation: CFrame?,
}
type ServerRecordData = {
	Model: Model?,
	InstanceCopy: (BasePart | Model)?,
	Key: Trackable,
	PrimaryPart: BasePart,
	Parent: Instance,
	CFrame: {
		-- Current: CFrame,
		-- Target: CFrame,
		Last: CFrame
	},
}
type ServerReplicationRecord = {
	Source: ServerRecordData,
	Instance: Trackable,
	Position: Vector3?,
	Rotation: Vector3?,
	Axis: Vector3?,
	Angle: number?
}
type DataId = "Add" | "Move" | "Del"
type ReplicatedMove = {
	I: Trackable?,
	P: string?,
	A: string?,
}
type Packet = {
	Id: DataId,
	Instance: Trackable?,
	Parent: Instance?,
	Moves: {[number]: ReplicatedMove},
}
type PlayerData = {
	ReplicationRecords: {[Trackable]: ServerReplicationRecord},
	Player: Player,
	Gui: ScreenGui
}
type SmoothLerpable = CFrame | number
export type KinematicObjectService = {
	__index: KinematicObjectService,
	_Maid: Maid,
	_IsAlive: boolean,
	_SmoothFactor: number,
	_RemoteEvent: RemoteEvent,
	_ClientRegistry: {[Trackable]: ClientRecordData},
	_ServerRegistry: {[Trackable]: ServerRecordData},
	_PlayerDataRegistry: {[number]: PlayerData},
	_ServerCamera: Camera,
	TAG_NAME: string,
	EPSILON: number,
	SERVER_HZ: number,
	SetSmoothFactor: (self: KinematicObjectService, smoothFactor: number) -> (),
	Insert: (self: KinematicObjectService, target: Trackable) -> (),
	Remove: (self: KinematicObjectService, target: Trackable) -> (),
	_ReplicateToPlayer: (self: KinematicObjectService, playerData: PlayerData, serverRecord: ServerRecordData) -> (),
	_GetClientRecord: (self: KinematicObjectService, target: Trackable) -> ClientRecordData?,
	Destroy: (self: KinematicObjectService) -> (),
	new: () -> KinematicObjectService,
	init: (maid: Maid) -> nil
}

-- Constants
local KINEMATIC_OBJECT_DATA_EVENT_NAME = "KinematicObjectServiceData"
local REPLICATION_SUFFIX = "_REPLICATED"
local DEFAULT_SMOOTH_FACTOR = 0.999
-- Variables


-- References
-- Private Functions
function smoothLerp<T>(a: T & SmoothLerpable, b: T & SmoothLerpable, fraction: number, deltaTime: number): T

	local f = 1.0 - math.pow(1.0 - fraction, deltaTime)

	if (type(a) == "number") then
		assert(type(b) == "number")
		return ((1-f) * a) + (b * f)
	elseif typeof(a) == "CFrame" then
		return a:Lerp(b, f)
	else
		error(`bad type {typeof(a)}`)
	end
end

-- Class
local CurrentKinematicObjectService: KinematicObjectService = nil :: any
local KinematicObjectService = {} :: KinematicObjectService
KinematicObjectService.__index = KinematicObjectService
KinematicObjectService.TAG_NAME = "KinematicObject"
KinematicObjectService.EPSILON = 0.00001
KinematicObjectService.SERVER_HZ = 20
function KinematicObjectService:Destroy()
	if not self._IsAlive then return end
	self._IsAlive = false
	if CurrentKinematicObjectService == self then
		CurrentKinematicObjectService = nil :: any
	end
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
end


function KinematicObjectService:_ReplicateToPlayer(playerData: PlayerData, serverRecord: ServerRecordData)
	if playerData.ReplicationRecords[serverRecord.Key]then
		return
	end
	-- print("Sending instance to player ", serverRecord)
	if serverRecord.InstanceCopy then
		local clone: Instance = serverRecord.InstanceCopy:Clone()
		clone.Name = clone.Name .. REPLICATION_SUFFIX
		
		local replicationRecord: ServerReplicationRecord = {
			Source = serverRecord,
			Instance = clone :: Trackable,
		}
	
		playerData.ReplicationRecords[serverRecord.Key] = replicationRecord 
		
		clone.Parent = playerData.Gui
	
		local repData: Packet = {
			Id = "Add", 
			Instance = clone :: Trackable,
			Parent = serverRecord.Parent,
			Moves = {},
		}
	
		self._RemoteEvent:FireClient(playerData.Player, repData)
	end
	
end

function KinematicObjectService:Insert(target: Trackable): ()
	if RunService:IsClient() then
		if self._ClientRegistry[target] then return end

		local model: Model? = if target:IsA("Model") then target else nil
		local inst: BasePart? = if target:IsA("Model") then target.PrimaryPart else target

		assert(inst ~= nil, if target:IsA("Model") then `model requires primary part {target:GetFullName()}` else `bad trackable instance {target:GetFullName()}`)

		local parts: {[number]: BasePart} = {}
		for i, part in ipairs(target:GetDescendants()) do
			if part:IsA("BasePart") and part.Anchored then
				table.insert(parts, part)
			end
		end
		
		local record: ClientRecordData = {
			Model = model,
			PrimaryPart = inst,
			Key = target,
			Parts = parts,
			CFrame = {
				Current = inst:GetPivot(),
				Target = inst:GetPivot(),
				Last = inst:GetPivot(),
			},
			Position = nil,
			Rotation = nil,
		}

		self._ClientRegistry[record.Key] = record
	else
		
		if (target:IsA("BasePart") == false and target:IsA("Model") == false) then
			error("Kinematic tags must be applied to baseparts and models only:")
		end
		
		local primaryPart: BasePart?
		local model: Model?
		if (target:IsA("Model")) then
			if (target.PrimaryPart == nil) then
				error(`Kinematic - No primarypart for {target:GetFullName()}`)
			end 
			primaryPart = target.PrimaryPart
			model = target
		else
			primaryPart = target
			model = nil
		end
		assert(primaryPart)

		--Store data
		local parent = target.Parent
		assert(parent)
		local record: ServerRecordData = {
			Key = target,
			Parent = parent, 
			PrimaryPart = primaryPart, 
			Model = model,
			InstanceCopy = if target then target:Clone() else nil,
			CFrame = {
				Last = primaryPart.CFrame,
			},
		}

		
		CollectionService:RemoveTag(primaryPart, KinematicObjectService.TAG_NAME)
		for i,value in ipairs(target:GetDescendants()) do
			CollectionService:RemoveTag(value, KinematicObjectService.TAG_NAME)
			if (value:IsA("Script")) then
				value:Destroy()
			end
		end
		
		self._ServerRegistry[target] = record
		
		--set initial instance values
		primaryPart.Anchored = true
		primaryPart.AssemblyAngularVelocity = Vector3.zero
		primaryPart.AssemblyLinearVelocity = Vector3.zero
		
		--pull it out of the world	
		local tInst = target :: Instance
		tInst.Parent = self._ServerCamera
		
		--Capture the destroy
		self._Maid:GiveTask(target.Destroying:Connect(function()
			self:Remove(target)
		end))
		
		--Replicate the waldo 
		for key,playerRecord in pairs(self._PlayerDataRegistry) do
			self:_ReplicateToPlayer(playerRecord, record)
		end
	end
end

function KinematicObjectService:_GetClientRecord(target: Trackable): ClientRecordData?
	return self._ClientRegistry[target]
end

function KinematicObjectService:Remove(target: Trackable): ()
	if RunService:IsClient() then
		local record: ClientRecordData? = self._ClientRegistry[target]
		if not record then return end
		assert(record)
	
		self._ClientRegistry[target] = nil
	
		record.Key:Destroy()
	else
		local record: ServerRecordData? = self._ServerRegistry[target]
		if not record then return end
		assert(record)

		for k, playerData in pairs(self._PlayerDataRegistry) do
			local rec = playerData.ReplicationRecords[target]
			if rec then
				self._RemoteEvent:FireClient(playerData.Player, { Id = "Del", i = rec.Instance })
				playerData.ReplicationRecords[target] = nil
			end
		end
		
		if record.InstanceCopy then
			record.InstanceCopy:Destroy()

		end

		self._ServerRegistry[target] = nil
	end
end

function KinematicObjectService:SetSmoothFactor(smoothFactor: number)
	assert(RunService:IsClient())
	self._SmoothFactor = smoothFactor
end

function KinematicObjectService.new()

	local self: KinematicObjectService = setmetatable({}, KinematicObjectService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._SmoothFactor = DEFAULT_SMOOTH_FACTOR
	self._ClientRegistry = {}
	self._PlayerDataRegistry = {}
	self._ServerRegistry = {}

	if RunService:IsClient() then
		-- print("Client boot")
		self._RemoteEvent = NetworkUtil.getRemoteEvent(KINEMATIC_OBJECT_DATA_EVENT_NAME)
		self._Maid:GiveTask(self._RemoteEvent.OnClientEvent:Connect(function(data: Packet)
			-- print("on client", data)
			if data.Id == "Add" then
				-- print("ADD", data)
				local inst = data.Instance
				assert(inst)

				if data.Parent then
					if inst:IsA("BasePart") then
						inst.Parent = data.Parent
					elseif inst:IsA("Model") then
						inst.Parent = data.Parent
					end
				end

				self:Insert(inst)

			elseif data.Id == "Move" then
				for key, move in pairs(data.Moves) do
					local inst = move.I
					-- print(key, inst)
					if inst then
						local record = self:_GetClientRecord(inst)
						assert(record, `record missing for {inst:GetFullName()}`)
						-- print(move.P)
						if move.P then
							local posx, posy, posz = string.unpack("fff", move.P)
							-- print(posx, posy, posz)
							record.Position = CFrame.new(Vector3.new(posx, posy, posz)) 
						end
						if move.A then
							local axisx, axisy, axisz, angle = string.unpack("ffff", move.A)
							record.Rotation = CFrame.fromAxisAngle(Vector3.new(axisx, axisy, axisz), angle)
						end
					end
				end
			elseif data.Id == "Del" then
				local inst = data.Instance
				assert(inst)
				self:Insert(inst)
			end
		end))

		self._Maid:GiveTask(RunService.PreSimulation:Connect(function(deltaTime: number)
			for key, record in pairs(self._ClientRegistry) do
				local pos = record.Position
				local rot = record.Rotation
				if not pos or not rot then
					continue
				end
				assert(pos and rot)
				record.CFrame.Target = pos * rot
				record.CFrame.Last = record.CFrame.Current
				record.CFrame.Current = smoothLerp(record.CFrame.Current, record.CFrame.Target, self._SmoothFactor, deltaTime)
				if record.Model then
					record.Model:PivotTo(record.CFrame.Current)
				else
					record.PrimaryPart:PivotTo(record.CFrame.Current)
				end

				local deltaPos = record.CFrame.Current.Position - record.CFrame.Last.Position
				local deltaRot = record.CFrame.Current.Rotation * record.CFrame.Last.Rotation:Inverse()
				local eX, eY, eZ = deltaRot:ToEulerAnglesXYZ()
				local deltaAngle = Vector3.new(eX, eY, eZ)

				if record.Model then
					for k, part in pairs(record.Parts) do
						part.AssemblyLinearVelocity = deltaPos / deltaTime
						part.AssemblyAngularVelocity = deltaAngle / deltaTime
					end
				else
					record.PrimaryPart.AssemblyLinearVelocity = deltaPos / deltaTime
					record.PrimaryPart.AssemblyAngularVelocity = deltaAngle / deltaTime
				end
			end
		end))
	else
		self._ServerCamera = self._Maid:GiveTask(Instance.new("Camera"))
		self._ServerCamera.Name = "DoNotReplicate"
		self._ServerCamera.Parent = workspace


		self._RemoteEvent = self._Maid:GiveTask(NetworkUtil.getRemoteEvent(KINEMATIC_OBJECT_DATA_EVENT_NAME))
		local timeOfNextUpdate = 0


		local function buildPacketForPlayer(playerRecord: PlayerData)
			-- print("build package", playerRecord)
			local moves: {[number]: ReplicatedMove} = {}	
			local send = false
			for key,record in pairs(playerRecord.ReplicationRecords) do
				
				local write = false
				local inst = record.Instance

				local cf: CFrame
				if record.Source.Key:IsA("Model") then
					cf = record.Source.Key:GetPivot()
				else
					cf = record.Source.Key:GetPivot()
				end

				local p: Vector3 = cf.Position
				local axis, angle = cf:ToAxisAngle()
				
				local encodedP: string?

				if (record.Position == nil or record.Position:FuzzyEq(p,self.EPSILON) == false) then
					encodedP = string.pack("fff", p.X, p.Y, p.Z)
					write = true
				end
				record.Position = p
				-- print("rP", record.Position)
				
				local encodedA: string?

				if (record.Rotation == nil or (record.Axis and record.Axis:FuzzyEq(axis,self.EPSILON) == false) or (record.Angle and math.abs(record.Angle - angle) > self.EPSILON)) then
					encodedA = string.pack("ffff", axis.X, axis.Y, axis.Z, angle)
					write = true
				end
				record.Angle = angle
				record.Axis = axis
						
				-- assert(encodedP)
				-- assert(encodedA)

				local rec: ReplicatedMove = {
					I = inst, 
					P = encodedP,
					A = encodedA,
				}
			
				if (write == true) then
					table.insert(moves, rec)
					send = true
				end
			end
			

			if (send == true) then
				local packet: Packet = {
					Id = "Move",
					Moves = moves,
				}
				self._RemoteEvent:FireClient(playerRecord.Player, packet)
			end
		end
		
		local function bootPlayer(player: Player)
			local playerRecord: PlayerData = {
				ReplicationRecords = {},
				Player = player,
				Gui = self._Maid:GiveTask(Instance.new("ScreenGui")),
			}
			self._PlayerDataRegistry[player.UserId] = playerRecord
			
			--Create a place to put their stuff
			playerRecord.Gui.ResetOnSpawn = false
			playerRecord.Gui.Name = "Kinematics"
			playerRecord.Gui.Parent = playerRecord.Player:WaitForChild("PlayerGui", 15)
					
			for trackable, record in pairs(self._ServerRegistry) do
				self:_ReplicateToPlayer(playerRecord, record)
			end
		end

		self._Maid:GiveTask(Players.PlayerAdded:Connect(bootPlayer))
		for i, player in ipairs(Players:GetPlayers()) do
			bootPlayer(player)
		end

		self._Maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
			local playerData = self._PlayerDataRegistry[player.UserId]
			self._PlayerDataRegistry[player.UserId] = nil :: any
			for k, v in pairs(playerData.ReplicationRecords) do
				playerData.ReplicationRecords[k] = nil
			end
			playerData.Gui = nil :: any
		end))
		
		self._Maid:GiveTask(RunService.PreSimulation:Connect(function(deltaTime: number)
				
			for i,target in ipairs(CollectionService:GetTagged(self.TAG_NAME)) do
				if target:IsA("BasePart") or target:IsA("Model") then
					if not self._ServerRegistry[target] then
						self:Insert(target)
					end
				end
			end

			for key,record in pairs(self._ServerRegistry) do

				local currentCFrame = record.PrimaryPart:GetPivot()
				local deltaPos = currentCFrame.Position - record.CFrame.Last.Position
				local deltaRot =  currentCFrame.Rotation * record.CFrame.Last.Rotation:Inverse()
				local x,y,z = deltaRot:ToEulerAnglesXYZ()
				local deltaAngle = Vector3.new(x,y,z)

				record.CFrame.Last = currentCFrame
				record.PrimaryPart.AssemblyLinearVelocity = deltaPos / deltaTime
				record.PrimaryPart.AssemblyAngularVelocity = deltaAngle / deltaTime
			end
			
			timeOfNextUpdate+=deltaTime

			if (timeOfNextUpdate > 1/self.SERVER_HZ) then
				timeOfNextUpdate = math.fmod(timeOfNextUpdate, 1/self.SERVER_HZ)
				
				for key,playerRecord in pairs(self._PlayerDataRegistry) do
					buildPacketForPlayer(playerRecord)
				end
			end
		end))
	end

	if CurrentKinematicObjectService ~= nil then
		 CurrentKinematicObjectService:Destroy()
		 CurrentKinematicObjectService = nil :: any
	end
	CurrentKinematicObjectService = self

	return self
end

function KinematicObjectService.init(maid: Maid)
	maid:GiveTask(KinematicObjectService.new())
	return nil
end

return ServiceProxy(function()
	return CurrentKinematicObjectService or KinematicObjectService
end)

