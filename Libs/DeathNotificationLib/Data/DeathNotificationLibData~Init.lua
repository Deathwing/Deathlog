local VERSION = 1785974400

if DeathNotificationLibData and (DeathNotificationLibData.VERSION or 0) >= VERSION then return end

---@class DeathNotificationLibData
---@field Internal _dnld
DeathNotificationLibData = { VERSION = VERSION, Internal = {} }

local _dnld = DeathNotificationLibData.Internal ---@class _dnld
