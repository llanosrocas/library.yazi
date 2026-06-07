---@diagnostic disable: undefined-global

local M = {}

---Runs an external command
---@param cmd string The command to run
---@param args string[] Arguments to pass to the command
---@param raw boolean|nil If true, return raw binary output without trimming
---@return string|nil
local function exec(cmd, args, raw)
  local out =
    Command(cmd):arg(args):stdout(Command.PIPED):stderr(Command.NULL):output()

  if not out or not out.status.success then
    return nil
  end

  if raw then
    return #out.stdout > 0 and out.stdout or nil
  end

  local s = out.stdout:gsub("%s+$", "")
  return #s > 0 and s or nil
end

---Converts a date string to yyyy-mm-dd or yyyy format
---@param date string|nil
---@return string|nil
local function normalize_date(date)
  if not date then
    return nil
  end
  return date:match("^(%d%d%d%d%-%d%d%-%d%d)") or date:match("^(%d%d%d%d)")
end

---Reads raw FB2 file content (handles .fb2 and .fb2.zip)
---@param src string Path to the FB2 file
---@return string|nil
local function read_fb2(src)
  if src:match("%.fb2%.zip$") or src:match("%.fbz$") then
    return exec("unzip", { "-p", src })
  end

  local f = io.open(src, "r")
  if not f then
    return nil
  end

  local content = f:read("*a")
  f:close()

  return content
end

---@class Fb2Meta
---@field title string|nil
---@field author string|nil
---@field isbn string|nil
---@field series string|nil
---@field subject string|nil
---@field date string|nil
---@field publisher string|nil
---@field language string|nil
---@field rating string|nil

---Parses metadata from FB2 XML content
---@param xml string|nil Raw FB2 XML content
---@return Fb2Meta|nil
local function get_meta(xml)
  if not xml then
    return nil
  end

  local author
  local author_block = xml:match("<author>(.-)</author>")
  if author_block then
    local parts = {}
    for _, tag in ipairs({ "first%-name", "middle%-name", "last%-name" }) do
      local v = author_block:match("<" .. tag .. ">([^<]+)</" .. tag .. ">")
      if v and v:match("%S") then
        parts[#parts + 1] = v
      end
    end
    if #parts > 0 then
      author = table.concat(parts, " ")
    end
  end

  local series
  local seq_tag = xml:match("<sequence[^>]*/>") or xml:match("<sequence[^>]*>")
  if seq_tag then
    local name = seq_tag:match('name="([^"]+)"')
    local number = seq_tag:match('number="([^"]+)"')
    if name then
      series = name .. (number and " #" .. number or "")
    end
  end

  local subjects = {}
  for genre in xml:gmatch("<genre[^>]*>([^<]+)</genre>") do
    if genre:match("%S") then
      subjects[#subjects + 1] = genre
    end
  end

  local pub_block = xml:match("<publish%-info>(.-)</publish%-info>")
  local publisher = pub_block
    and pub_block:match("<publisher>([^<]+)</publisher>")
  local pub_year = pub_block and pub_block:match("<year>([^<]+)</year>")

  local isbn = (pub_block and pub_block:match("<isbn>([^<]+)</isbn>"))
    or xml:match("<isbn>([^<]+)</isbn>")

  local date_attr = xml:match('<date[^>]*value="([^"]+)"')
  local date_tag = xml:match("<date[^>]*>([^<]*)</date>")
  local date = normalize_date(date_attr or date_tag or pub_year)

  return {
    title = xml:match("<book%-title>([^<]+)</book%-title>"),
    author = author,
    isbn = isbn,
    series = series,
    subject = #subjects > 0 and table.concat(subjects, ", ") or nil,
    date = date,
    publisher = publisher,
    language = xml:match("<lang>([^<]+)</lang>"),
    rating = nil,
  }
end

---Decodes a base64 string to binary
---@param s string Base64-encoded string
---@return string
local function b64decode(s)
  local lookup = {}
  local alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #alphabet do
    lookup[alphabet:sub(i, i)] = i - 1
  end

  s = s:gsub("[^A-Za-z0-9+/=]", "")

  local t = {}
  for i = 1, #s, 4 do
    local a = lookup[s:sub(i, i)] or 0
    local b = lookup[s:sub(i + 1, i + 1)] or 0
    local c = lookup[s:sub(i + 2, i + 2)] or 0
    local d = lookup[s:sub(i + 3, i + 3)] or 0
    local n = a * 262144 + b * 4096 + c * 64 + d
    t[#t + 1] = string.char((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
  end

  local pad = s:match("=*$")
  local result = table.concat(t)
  return result:sub(1, #result - #pad)
end

---Extracts and resizes the cover image embedded in an FB2 file.
---FB2 stores covers as base64 inside <binary id="..."> referenced by
---<coverpage><image l:href="#id"/></coverpage>.
---@param xml string Raw FB2 XML content
---@return string|nil Path to extracted (and resized) cover image tmp file
local function get_cover(xml)
  local coverpage = xml:match("<coverpage>(.-)</coverpage>")
  if not coverpage then
    return nil
  end

  local cover_id = coverpage:match('l:href="#([^"]+)"')
    or coverpage:match('href="#([^"]+)"')
  if not cover_id then
    return nil
  end

  local escaped_id = cover_id:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")

  local mime = xml:match(
    '<binary[^>]*id="' .. escaped_id .. '"[^>]*content%-type="([^"]+)"'
  ) or xml:match(
    '<binary[^>]*content%-type="([^"]+)"[^>]*id="' .. escaped_id .. '"'
  )

  local tag_end =
    select(2, xml:find('<binary[^>]*id="' .. escaped_id .. '"[^>]*>'))
  if not tag_end then
    return nil
  end

  local close_start = xml:find("</binary>", tag_end + 1, true)
  if not close_start then
    return nil
  end

  local b64 = xml:sub(tag_end + 1, close_start - 1):gsub("%s+", "")
  if #b64 == 0 then
    return nil
  end

  local data = b64decode(b64)
  if #data < 100 then
    return nil
  end

  local ext = (mime and mime:match("/([^;]+)")) or "jpg"
  if ext == "jpeg" then
    ext = "jpg"
  end

  local cover_tmp = os.tmpname() .. "." .. ext
  local f = io.open(cover_tmp, "wb")
  if not f then
    return nil
  end
  f:write(data)
  f:close()

  local cover_resized = cover_tmp .. ".resized.jpg"
  exec(
    "ffmpeg",
    { "-y", "-i", cover_tmp, "-vf", "scale=1200:-2", cover_resized }
  )

  local rf = io.open(cover_resized, "rb")
  if rf and rf:seek("end") > 200 then
    rf:close()
    os.remove(cover_tmp)
    return cover_resized
  end

  if rf then
    rf:close()
  end
  os.remove(cover_resized)
  return cover_tmp
end

---Renders a single metadata row with a cyan label and value
---@param label string Display label
---@param value string|nil
---@return table|nil ui.Line
local function render_row(label, value)
  if not value then
    return nil
  end

  return ui.Line({
    ui.Span(string.format("%-12s", label .. ":")):style(ui.Style():fg("cyan")),
    ui.Span(" " .. value),
  })
end

---Renders the cover image into the given area
---@param cover string Path to cover image
---@param img_area table ui.Rect
local function render_cover(cover, img_area)
  local url = Url(cover)
  local cache = Url(cover .. ".cache")
  ya.image_precache(url, cache)
  ya.image_show(cache, img_area)
end

---Splits a preview area into image and text sections
---@param area table ui.Rect
---@param img_h integer
---@return table img_area, table txt_area
local function split_area(area, img_h)
  return ui.Rect({ x = area.x, y = area.y, w = area.w, h = img_h }),
    ui.Rect({
      x = area.x,
      y = area.y + img_h + 1,
      w = area.w,
      h = area.h - img_h - 1,
    })
end

function M:peek(job)
  local src = tostring(job.file.url)
  local xml = read_fb2(src)
  local meta = get_meta(xml)

  local cache = ya.file_cache(job)
  local cover

  if cache and fs.cha(cache) then
    cover = tostring(cache)
  else
    local cover_tmp = xml and get_cover(xml)
    if cover_tmp and cache then
      exec("cp", { cover_tmp, tostring(cache) })
    end
    cover = cover_tmp
  end

  local area = job.area
  local txt_area

  if cover then
    local img_area
    img_area, txt_area = split_area(area, 18)
    render_cover(cover, img_area)
  else
    txt_area = area
  end

  local lines = {}
  if meta then
    local function add(label, value)
      local r = render_row(label, value)
      if r then
        lines[#lines + 1] = r
      end
    end
    add("Title", meta.title)
    add("Author", meta.author)
    add("ISBN", meta.isbn)
    add("Series", meta.series)
    add("Subject", meta.subject)
    add("Date", meta.date)
    add("Publisher", meta.publisher)
    add("Language", meta.language)
  end

  ya.preview_widget(job, ui.Text(lines):area(txt_area))
end

function M:seek() end

function M:spot(job)
  local src = tostring(job.file.url)
  local xml = read_fb2(src)
  local meta = get_meta(xml)

  if not meta then
    return
  end

  local rows = {}
  for _, pair in ipairs({
    { "Title", meta.title },
    { "Author", meta.author },
    { "ISBN", meta.isbn },
    { "Series", meta.series },
    { "Subject", meta.subject },
    { "Date", meta.date },
    { "Publisher", meta.publisher },
    { "Language", meta.language },
  }) do
    if pair[2] then
      rows[#rows + 1] = ui.Row({ "  " .. pair[1] .. ":", pair[2] })
    end
  end

  ya.spot_table(
    job,
    ui.Table(rows)
      :area(ui.Pos({ "center", w = 70, h = 20 }))
      :row(job.skip)
      :row(0)
      :col(1)
      :col_style(th.spot.tbl_col)
      :cell_style(th.spot.tbl_cell)
      :widths({ ui.Constraint.Length(14), ui.Constraint.Fill(1) })
  )
end

return M
