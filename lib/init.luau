local CollectionService = game:GetService("CollectionService")

local Janitor = require(script.Parent.Janitor)
local Promise = require(script.Parent.Promise)
local Signal = require(script.Parent.Signal)

-->-------<--
--> Types <--
-->-------<--

export type Component<T> = {
	Tag: string,

	Started: Signal.Signal<T>,
	Stopped: Signal.Signal<T>,

	GetAll: (self: Component<T>) -> {T},
	FromInstance: (self: Component<T>, instance: Instance) -> T?,
	WaitForInstance: (self: Component<T>, instance: Instance) -> Promise.TypedPromise<T>,

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
	_janitor: Janitor.Janitor,
	_ancestors: {Instance},
	_components: {[ComponentInstance<T>]: true},
	_instanceMap: {[Instance]: ComponentInstance<T>},
	_started: boolean,
}

-->---------<--
--> Private <--
-->---------<--

local DEFAULT_ANCESTORS: {Instance} = {workspace}

local componentsByInstance: {[Instance]: {[string]: ComponentInstance<unknown>}} = {}

local function isInAncestorList<T>(self: InternalComponent<T>, instance: Instance): boolean
	for _, ancestor: Instance in ipairs(self._ancestors) do
		if not instance:IsDescendantOf(ancestor) then continue end
		return true
	end
	return false
end

local function extend<T>(self: InternalComponent<T>, instance: Instance): ComponentInstance<T>?
	if self._instanceMap[instance] then
		return self._instanceMap[instance]
	end

	if type(self.CanExtend) == "function" and not self.CanExtend(self, instance) then return end

	--> Create the component instance
	local component = setmetatable({
		Instance = instance,
		Janitor = Janitor.new(),
	}, self)

	--> Register in maps
	self._components[component] = true
	self._instanceMap[instance] = component

	if not componentsByInstance[instance] then
		componentsByInstance[instance] = {}
	end
	componentsByInstance[instance][self.Tag] = component

	--> Set up cleanup
	component.Janitor:Add(function()
		self._components[component] = nil
		self._instanceMap[instance] = nil

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
	-- if self._started and type(component.onStart) == "function" then
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
	self._janitor = Janitor.new()
	self._ancestors = options.Ancestors or DEFAULT_ANCESTORS
	self._components = {}
	self._instanceMap = {}
	self._started = false
	self.Tag = options.Tag
	self.Started = Signal.new()
	self.Stopped = Signal.new()
	setmetatable(self, Component)

	self:Start()
	return self :: any
end

function Component.FromInstance<T>(self: InternalComponent<T>, instance: Instance): T?
	return self._instanceMap[instance]
end

function Component.WaitForInstance<T>(self: InternalComponent<T>, instance: Instance): Promise.TypedPromise<T>
	local componentInstance: T? = self._instanceMap[instance]
	if componentInstance then
		return Promise.resolve(componentInstance)
	end
	return Promise.fromEvent(self.Started, function(startedComponentInstance: T & ComponentInstance<unknown>)
		local match: boolean = startedComponentInstance.Instance == instance
		if match then
			componentInstance = startedComponentInstance
		end
		return match
	end):andThen(function()
		return componentInstance
	end)
end

function Component.GetAll<T>(self: InternalComponent<T>): {ComponentInstance<T>}
	local result: {ComponentInstance<T>} = {}
	for component in pairs(self._components) do
		table.insert(result, component)
	end
	return result
end

function Component.Start(self: InternalComponent<ComponentInstance<unknown>>)
	if self._started then return end
	self._started = true

	local function tryConstructComponent(instance: Instance)
		if not isInAncestorList(self, instance) then return end

		local component: ComponentInstance<unknown>? = extend(self, instance)
		if not component then return end

		if type(component.onStart) == "function" then
			component.onStart(component)
		end

		self.Started:Fire(component)
	end

	local function tryDeconstructComponent(instance: Instance)
		local component: ComponentInstance<unknown>? = self:FromInstance(instance)
		if not component then return end

		if type(component.onStop) == "function" then
			component.onStop(component)
		end

		component.Janitor:Cleanup()
		self.Stopped:Fire(component)
	end

	self._janitor:Add(CollectionService:GetInstanceAddedSignal(self.Tag):Connect(tryConstructComponent), "Disconnect") --> Listen for new instances
	self._janitor:Add(CollectionService:GetInstanceRemovedSignal(self.Tag):Connect(tryDeconstructComponent), "Disconnect") --> Listen for removed instances

	--> Handle existing instances
	for _, instance: Instance in ipairs(CollectionService:GetTagged(self.Tag)) do
		task.defer(tryConstructComponent, instance)
	end
end

function Component.Stop(self: InternalComponent<unknown>)
	if not self._started then return end
	self._started = false

	--> Stop all components
	for component: ComponentInstance<unknown> in pairs(self._components) do
		if type(component.onStop) == "function" then
			task.spawn(component.onStop, component)
		end
		component.Janitor:Cleanup()
		self.Stopped:Fire(component)
	end

	--> Clear the component maps
	table.clear(self._components)
	table.clear(self._instanceMap)

	--> Clean up listeners
	self._janitor:Cleanup()
end

return Component