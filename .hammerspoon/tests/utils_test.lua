local root = assert(arg[1])
local calls, screens, data, err = 0, 0, nil, nil
local utils = assert(loadfile(
  root .. "/utils.lua",
  "t",
  setmetatable({
    hs = {
      spaces = {
        data_managedDisplaySpaces = function()
          calls = calls + 1
          return data, err
        end,
      },
      screen = {
        mainScreen = function()
          screens = screens + 1
          return {
            getUUID = function()
              return "MAIN-UUID"
            end,
          }
        end,
      },
    },
  }, { __index = _G })
))()
local passed = 0
local function test(name, body)
  calls, screens = 0, 0
  body()
  passed = passed + 1
  print("PASS " .. name)
end
test("ordered Spaces carry their display UUID from one native snapshot", function()
  data = {
    {
      ["Display Identifier"] = "Main",
      Spaces = { { ManagedSpaceID = 10 }, { ManagedSpaceID = 11 } },
    },
    {
      ["Display Identifier"] = "SIDE-UUID",
      Spaces = { { ManagedSpaceID = 20 }, { ManagedSpaceID = 21 } },
    },
  }
  local spaces = assert(utils.spaces())
  assert(calls == 1 and screens == 1 and #spaces == 4)
  for index, id in ipairs({ 10, 11, 20, 21 }) do
    assert(spaces[index].ManagedSpaceID == id)
    assert(spaces[index].display == (id < 20 and "MAIN-UUID" or "SIDE-UUID"))
  end
end)
test("named displays never query the main screen", function()
  data = { { ["Display Identifier"] = "SIDE-UUID", Spaces = { { ManagedSpaceID = 1 } } } }
  assert(utils.spaces()[1].display == "SIDE-UUID" and screens == 0)
end)
test("native snapshot errors propagate", function()
  data, err = nil, "unavailable"
  local spaces, message = utils.spaces()
  assert(spaces == nil and message == err)
end)
print("RESULT " .. passed .. " passed, 0 failed")
