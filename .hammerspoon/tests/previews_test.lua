local modulePath = assert(arg[1], "pass the fixture module")
local cancel
local previews = assert(package.loadlib(modulePath, "luaopen_previews"))()
local fixture = assert(package.loadlib(modulePath, "luaopen_fixture"))()
local windows = {}
for id = 1, 7 do
  windows[#windows + 1] = { id = id, pid = 123 }
end
local function reload()
  fixture.prepare(true)
  cancel = previews.capture(windows, fixture.mark)
  fixture.waitStarted(4)
  fixture.reload()
end
local function collection()
  fixture.prepare(true)
  cancel = previews.capture(windows, function()
    error("collected capture called back")
  end)
  fixture.waitStarted(4)
  cancel = nil
  collectgarbage("collect")
  fixture.resume()
  fixture.idle(function()
    local _, _, captures = fixture.stats()
    assert(captures == 4)
    print("PASS collected cancellation handles release pending work safely")
    reload()
  end)
end
local function cancellation()
  fixture.prepare(true)
  cancel = previews.capture(windows, function()
    error("cancelled capture called back")
  end)
  fixture.waitStarted(4)
  cancel()
  cancel()
  fixture.resume()
  fixture.idle(function()
    local _, _, captures = fixture.stats()
    assert(captures == 4)
    print("PASS cancellation skips queued captures and suppresses callbacks")
    collection()
  end)
end
local function errors()
  fixture.prepare(false)
  local valid, failures, completed = 0, {}, 0
  cancel = previews.capture({
    { id = 1, pid = 123 },
    { id = 12, pid = 123 },
    { id = 13, pid = 123 },
    { id = 14, pid = 123 },
    { id = 15, pid = 123 },
    { id = 16, pid = 123 },
  }, function(id, image, err)
    if id then
      completed = completed + 1
      if image then
        assert(id == 1)
        valid = valid + 1
      end
      if err then
        failures[id] = err
      end
      return
    end
    assert(completed == 6 and valid == 1)
    assert(failures[13] == "could not capture window: 13")
    assert(failures[16] == "could not capture window: 16")
    assert(not failures[12] and not failures[14] and not failures[15])
    local _, starts = fixture.stats()
    assert(starts == 4)
    print("PASS failures, placeholder images, and reused window IDs never corrupt previews")
    cancellation()
  end)
end
local function empty()
  fixture.prepare(false)
  cancel = previews.capture({}, function(id, image, err)
    assert(id == nil and image == nil and err == nil)
    print("PASS empty batch completes asynchronously")
    errors()
  end)
end
local function overlap()
  fixture.prepare(true)
  local many = {}
  for id = 1000, 1099 do
    many[#many + 1] = { id = id, pid = 123 }
  end
  local old = previews.capture(many, function()
    error("superseded batch called back")
  end)
  fixture.waitStarted(4)
  old()
  local images = 0
  cancel = previews.capture(windows, function(id, image, err)
    assert(not err)
    if id then
      assert(image)
      images = images + 1
      return
    end
    local peak, starts, captured = fixture.stats()
    assert(images == 7 and peak == 4 and starts == 11 and captured == 11)
    print("PASS replacing 100 queued captures keeps the global four-worker limit")
    empty()
  end)
  fixture.resume()
end
local function hundred()
  fixture.prepare(false)
  local many, images, bytes = {}, 0, 0
  for id = 1000, 1099 do
    many[#many + 1] = { id = id, pid = 123 }
  end
  cancel = previews.capture(many, function(id, image, err)
    assert(not err)
    if id then
      assert(image.w == 460 and image.h == 260)
      images, bytes = images + 1, bytes + image.bytes
      return
    end
    assert(images == 100 and bytes <= 47 * 1024 * 1024)
    local peak, starts = fixture.stats()
    assert(peak <= 4 and starts == 100)
    print("PASS 100 real thumbnail bitmaps stay below 47 MiB with four workers")
    overlap()
  end)
end
local function dimensions()
  fixture.prepare(false)
  local seen = {}
  cancel = previews.capture(
    { { id = 8, pid = 123 }, { id = 9, pid = 123 } },
    function(id, image, err)
      assert(not err)
      if id then
        seen[id] = image
        return
      end
      assert(seen[8].w == 347 and seen[8].h == 260)
      assert(seen[9].w == 52 and seen[9].h == 260)
      print("PASS native resizing preserves aspect ratio and stores only thumbnail pixels")
      hundred()
    end
  )
end
local function progressive()
  fixture.prepare(true, 1)
  local first, images = true, 0
  cancel = previews.capture(windows, function(id, image, err)
    assert(not err)
    if id then
      assert(image.w == 8 and image.h == 8)
      images = images + 1
      if first then
        assert(id ~= 1)
        local _, _, captured = fixture.stats()
        assert(captured < 7)
        first = false
        fixture.resume()
      end
      return
    end
    assert(images == 7)
    print("PASS completed previews arrive while a slower capture is still blocked")
    dimensions()
  end)
  fixture.waitStarted(4)
end
local function independent()
  fixture.prepare(true)
  local cancellations, images, completions = {}, 0, 0
  for id = 1, 4 do
    cancellations[id] = previews.capture({ { id = id, pid = 123 } }, function(window, image, err)
      assert(not err)
      if window then
        assert(image and window == id)
        images = images + 1
      else
        completions = completions + 1
        if completions == 4 then
          local peak, starts, captures = fixture.stats()
          assert(
            #cancellations == 4 and images == 4 and peak == 4 and starts == 4 and captures == 4
          )
          print("PASS independent one-window captures share all four workers")
          progressive()
        end
      end
    end)
  end
  fixture.waitStarted(4)
  fixture.resume()
end
for _, window in ipairs({
  { id = 0, pid = 1 },
  { id = 1, pid = 0 },
  { id = -1, pid = 1 },
  { id = 1, pid = "bad" },
}) do
  assert(not pcall(previews.capture, { window }, function()
    error("invalid capture")
  end))
end
print("PASS malformed requests fail before starting work")
fixture.prepare(true)
local returned, images = false, 0
cancel = previews.capture(windows, function(id, image, err)
  assert(returned and not err)
  if id then
    assert(image.w == 8 and image.h == 8)
    images = images + 1
    return
  end
  local peak, starts, captures = fixture.stats()
  assert(images == 7 and peak == 4 and starts == 7 and captures == 7)
  print("PASS four concurrent workers deliver progressive results and one final completion")
  independent()
end)
returned = true
fixture.waitStarted(4)
fixture.resume()
