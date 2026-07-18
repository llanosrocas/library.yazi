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

---Extracts and returns the OPF manifest XML from an EPUB file
---@param src string Path to the EPUB file
---@return string|nil
local function get_opf(src)
  local container_xml = exec("unzip", { "-p", src, "META-INF/container.xml" })

  if not container_xml then
    return nil
  end

  local opf_path = container_xml:match('full%-path="([^"]+)"')

  local opf = exec("unzip", { "-p", src, opf_path })

  return opf
end

---@class EpubMeta
---@field title string|nil
---@field author string|nil
---@field isbn string|nil
---@field series string|nil
---@field subject string|nil
---@field date string|nil
---@field publisher string|nil
---@field language string|nil
---@field rating string|nil

---Parses metadata fields from an OPF manifest XML string.
---@param opf string|nil OPF manifest XML content
---@return EpubMeta|nil
local function get_meta(opf)
  if not opf then
    return nil
  end

  local isbn = opf:match(
    '<dc:identifier[^>]*opf:scheme="ISBN"[^>]*>([^<]+)</dc:identifier>'
  ) or opf:match(
    '<dc:identifier[^>]*scheme="ISBN"[^>]*>([^<]+)</dc:identifier>'
  ) or opf:match("<dc:identifier[^>]*>(%d[%d%-]+%d)</dc:identifier>")

  local series = opf:match(
    '<meta[^>]*name="calibre:series"[^>]*content="([^"]+)"'
  ) or opf:match('<meta[^>]*content="([^"]+)"[^>]*name="calibre:series"')

  local series_index = opf:match(
    '<meta[^>]*name="calibre:series_index"[^>]*content="([^"]+)"'
  ) or opf:match(
    '<meta[^>]*content="([^"]+)"[^>]*name="calibre:series_index"'
  )

  local subjects = {}
  for subject in opf:gmatch("<dc:subject[^>]*>([^<]+)</dc:subject>") do
    subjects[#subjects + 1] = subject
  end
  local subject = #subjects > 0 and table.concat(subjects, ", ") or nil

  local rating = opf:match(
    '<meta[^>]*name="calibre:rating"[^>]*content="([^"]+)"'
  ) or opf:match('<meta[^>]*content="([^"]+)"[^>]*name="calibre:rating"')

  return {
    title = opf:match("<dc:title[^>]*>([^<]+)</dc:title>"),
    author = opf:match("<dc:creator[^>]*>([^<]+)</dc:creator>"),
    isbn = isbn,
    series = series
        and (series .. (series_index and " #" .. series_index or ""))
      or nil,
    subject = subject,
    date = normalize_date(opf:match("<dc:date[^>]*>([^<]+)</dc:date>")),
    publisher = opf:match("<dc:publisher[^>]*>([^<]+)</dc:publisher>"),
    language = opf:match("<dc:language[^>]*>([^<]+)</dc:language>"),
    rating = rating,
  }
end

---Finds the cover image href from an OPF manifest.
---Tries EPUB 3 properties="cover-image", then id="cover-image",
---then falls back to EPUB 2 style meta name="cover" content="id".
---@param opf string OPF manifest XML content
---@return string|nil Relative path to cover image within the EPUB
local function get_cover_href(opf)
  local cover_tag = opf:match('<item[^>]*properties="cover%-image"[^>]*>')
    or opf:match('<item[^>]*id="cover%-image"[^>]*>')
  local cover_href = cover_tag and cover_tag:match('href="([^"]+)"')

  if not cover_href then
    local meta_tag = opf:match('<meta[^>]*name="cover"[^>]*>')
      or opf:match('<meta[^>]*content="[^"]*"[^>]*name="cover"[^>]*>')
    local cover_id = meta_tag and meta_tag:match('content="([^"]+)"')
    if cover_id then
      local item_tag = opf:match('<item[^>]*id="' .. cover_id .. '"[^>]*>')
      cover_href = item_tag and item_tag:match('href="([^"]+)"')
    end
  end

  return cover_href
end

---Extracts a cover image from the EPUB and resizes it to 1200px wide via ffmpeg.
---Returns path to the resized image, or original if ffmpeg fails.
---@param src string Path to the EPUB file
---@param cover_name string Path to cover image within the EPUB zip
---@param ext string File extension for the cover image e.g. "jpg"
---@return string|nil Path to extracted (and resized) cover image
local function extract_and_resize(src, cover_name, ext)
  local cover_data = exec("unzip", { "-p", src, cover_name }, true)
  if not cover_data then
    return nil
  end

  local cover_tmp = os.tmpname() .. "." .. ext
  local cover_file = io.open(cover_tmp, "wb")
  if not cover_file then
    return nil
  end

  cover_file:write(cover_data)
  cover_file:close()

  local cover_resized = cover_tmp .. ".resized.jpg"
  exec("magick", { cover_tmp, "-resize", "1200x", cover_resized })

  local resized_file = io.open(cover_resized, "rb")
  if resized_file and resized_file:seek("end") > 200 then
    resized_file:close()
    os.remove(cover_tmp)
    return cover_resized
  end

  if resized_file then
    resized_file:close()
  end

  os.remove(cover_resized)

  return cover_tmp
end

---Extracts and processes the cover image from an EPUB file
---@param src string Path to the EPUB file
---@param opf string|nil OPF manifest XML content
---@return string|nil Path to extracted cover image tmp file
local function get_cover(src, opf)
  if not opf then
    return nil
  end

  local cover_href = get_cover_href(opf)
  if not cover_href then
    return nil
  end

  local listing = exec("unzip", { "-l", src })
  local opf_path = listing and listing:match("[^%s]+%.opf")
  local opf_dir = opf_path and opf_path:match("^(.+)/[^/]+$") or ""
  local cover_name = opf_dir ~= "" and (opf_dir .. "/" .. cover_href)
    or cover_href
  local ext = cover_href:match("%.([^%.]+)$") or "jpg"

  return extract_and_resize(src, cover_name, ext)
end

---Renders a single metadata row with a cyan label and value
---@param label string Display label e.g. "Title"
---@param value string|nil Value to display
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

---Renders the cover image into the given area using Yazi's image pipeline
---Precaches the image for optimal rendering then displays it
---@param cover string Path to the cover image file
---@param img_area table ui.Rect defining the display area
local function render_cover(cover, img_area)
  local url = Url(cover)
  local cache = Url(cover .. ".cache")
  ya.image_precache(url, cache)
  ya.image_show(cache, img_area)
end

---Splits a preview area into image and text sections
---@param area table ui.Rect the full preview area
---@param img_h integer Number of rows to allocate for the image
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
  local opf = get_opf(src)
  local meta = get_meta(opf)

  local cache = ya.file_cache(job)
  local cover

  if cache and fs.cha(cache) then
    cover = tostring(cache)
  else
    local cover_tmp = get_cover(src, opf)
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
    add("Rating", meta.rating)
  end

  ya.preview_widget(job, ui.Text(lines):area(txt_area))
end

function M:seek() end

function M:spot(job)
  local src = tostring(job.file.url)
  local opf = get_opf(src)
  local meta = get_meta(opf)

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
    { "Rating", meta.rating },
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
