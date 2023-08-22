--!strict
-- Services
local RunService = game:GetService("RunService")
-- Packages
local Package = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("package"))
local Maid = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Maid"))
-- Modules
-- Types
-- Constants
-- Variables
-- References
-- Private Functions
-- Class
local primPart = workspace:WaitForChild("TeaPot") :: BasePart
-- local primPart = teaPot.PrimaryPart
assert(primPart)

local maid = Maid.new()
Package.init(maid)
Package:Insert(primPart)

local startPos: Vector3 = primPart.Position
local boxSize = 22

local vel = Vector3.new(10,0,12)
local pos = Vector3.new(0,0,0)

--This is just some simple server script that moves the object around every frame
--The kinematics module handles the rest
maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime: number)
	
	primPart.Position = startPos + pos
	
	pos += vel * deltaTime
	
	if (pos.X > boxSize) then
		vel = Vector3.new( -math.abs(vel.X),0,vel.Z)
	end
	if (pos.X < -boxSize) then
		vel = Vector3.new( math.abs(vel.X),0,vel.Z)
	end
	if (pos.Z > boxSize) then
		vel = Vector3.new(vel.X,0, -math.abs(vel.Z))
	end
	if (pos.Z < -boxSize) then
		vel = Vector3.new(vel.X,0, math.abs(vel.Z))
	end
	
end))
