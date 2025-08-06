local CollectionService = game:GetService("CollectionService")

local Janitor = require(script.Parent.Janitor)

-->-------<--
--> Types <--
-->-------<--

export type Component<T> = {
	Tag: string,

	GetAll: (self: Component<T>) -> {T},
	FromInstance: (self: Component<T>, instance: Instance) -> T?,

	CanExtend: ((self: Component<T>, instance: Instance) -> boolean)?,

	new: (options: {Tag: string, Ancestors: {Instance}?}) -> T,

	Start: (self: Component<T>) -> (),
	Stop: (self: Component<T>) -> (),
}

export type ComponentInstance<T> = T & {
	Tag: string,
	Janitor: Janitor.Janitor,
	Instance: Instance,

	onStart: ((self: ComponentInstance<T>) -> ())?,
	onStop: ((self: ComponentInstance<T>) -> ())?,
}

type InternalComponent<T> = Component<T> & {
	__janitor: Janitor.Janitor,
	__ancestors: {Instance},
	__components: {[ComponentInstance<T>]: true},
	__instanceMap: {[Instance]: ComponentInstance<T>},
	__started: boolean,
}

-->---------<--
--> Private <--
-->---------<--

local DEFAULT_ANCESTORS: {Instance} = {workspace}

local componentsByInstance: {[Instance]: {[string]: ComponentInstance<unknown>}} = {}

local function isInAncestorList<T>(self: InternalComponent<T>, instance: Instance): boolean
	for _, ancestor: Instance in ipairs(self.__ancestors) do
		if not instance:IsDescendantOf(ancestor) then continue end
		return true
	end
	return false
end

local function extend<T>(self: InternalComponent<T>, instance: Instance): ComponentInstance<T>?
	if self.__instanceMap[instance] then
		return self.__instanceMap[instance]
	end

	if type(self.CanExtend) == "function" and not self.CanExtend(self, instance) then return end

	--> Create the component instance
	local component = setmetatable({
		Instance = instance,
		Janitor = Janitor.new(),
	}, self)

	--> Register in maps
	self.__components[component] = true
	self.__instanceMap[instance] = component

	if not componentsByInstance[instance] then
		componentsByInstance[instance] = {}
	end
	componentsByInstance[instance][self.Tag] = component

	--> Set up cleanup
	component.Janitor:Add(function()
		self.__components[component] = nil
		self.__instanceMap[instance] = nil

		if componentsByInstance[instance] then
			componentsByInstance[instance][self.Tag] = nil

			if next(componentsByInstance[instance]) == nil then
				componentsByInstance[instance] = nil
			end
		end
	end, true)

	--> Register cleanup when instance is removed
	component.Janitor:Add(instance.AncestryChanged:Connect(function(_, parent: Instance?)
		if parent and isInAncestorList(self, instance) then return end
		component.Janitor:Cleanup()
	end), "Disconnect")

	-- --> If already started, initialize the component
	-- if self.__started and type(component.onStart) == "function" then
	-- 	task.spawn(component.onStart, component)
	-- end

	return component
end

-->-----------<--
--> Component <--
-->-----------<--

local Component = {}
Component.__index = Component

function Component.new<T>(options: {
	Tag: string,
	Ancestors: {Instance}?,
}): Component<T>
	assert(type(options.Tag) == "string", "Tag must be a string")

	local self = {}
	self.__index = self
	self.__tostring = function()
		return `Component<{options.Tag}>`
	end
	self.__janitor = Janitor.new()
	self.__ancestors = options.Ancestors or DEFAULT_ANCESTORS
	self.__components = {}
	self.__instanceMap = {}
	self.__started = false
	self.Tag = options.Tag
	setmetatable(self, Component)

	self:Start()
	return self :: any
end

function Component:FromInstance<T>(instance: Instance): T?
	return self.__instanceMap[instance]
end

function Component:GetAll<T>(): {ComponentInstance<T>}
	local result: {ComponentInstance<T>} = {}
	for component in pairs(self.__components) do
		table.insert(result, component)
	end
	return result
end

function Component.Start(self: InternalComponent<ComponentInstance<unknown>>)
	if self.__started then return end
	self.__started = true

	local function tryConstructComponent(instance: Instance)
		if not isInAncestorList(self, instance) then return end

		local component: ComponentInstance<unknown>? = extend(self, instance)
		if not component then return end

		if type(component.onStart) == "function" then
			component.onStart(component)
		end
	end

	local function tryDeconstructComponent(instance: Instance)
		local component: ComponentInstance<unknown>? = self:FromInstance(instance)
		if not component then return end

		if type(component.onStop) == "function" then
			component.onStop(component)
		end

		component.Janitor:Cleanup()
	end

	self.__janitor:Add(CollectionService:GetInstanceAddedSignal(self.Tag):Connect(tryConstructComponent), "Disconnect") --> Listen for new instances
	self.__janitor:Add(CollectionService:GetInstanceRemovedSignal(self.Tag):Connect(tryDeconstructComponent), "Disconnect") --> Listen for removed instances

	--> Handle existing instances
	for _, instance: Instance in ipairs(CollectionService:GetTagged(self.Tag)) do
		task.defer(tryConstructComponent, instance)
	end
end

function Component.Stop(self: InternalComponent<unknown>)
	if not self.__started then return end
	self.__started = false

	--> Stop all components
	for component: ComponentInstance<unknown> in pairs(self.__components) do
		if type(component.onStop) == "function" then
			task.spawn(component.onStop, component)
		end
		component.Janitor:Cleanup()
	end

	--> Clear the component maps
	table.clear(self.__components)
	table.clear(self.__instanceMap)

	--> Clean up listeners
	self.__janitor:Cleanup()
end

return Component