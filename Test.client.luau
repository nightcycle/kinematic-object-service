--!strict
-- Services
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
Package.init(Maid.new())