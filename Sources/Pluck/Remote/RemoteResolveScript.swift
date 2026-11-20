import Foundation

/// The DaVinci Resolve side of the remote round trip, on both Macs: the host builds a project from
/// the originals with proxies linked, imports an editor's project, swaps proxies for originals and
/// renders; the editor's Mac reads its open project, exports it, imports one from the host and
/// links the local proxies. Runs one call at a time with OfficeResolve's other calls.
///
/// Every Resolve call below was checked in the scripting API stubs (21.2, DaVinciResolveScript.pyi):
/// ProjectManager.CreateProject/LoadProject/DeleteProject/SaveProject/CloseProject/ImportProject/
/// ExportProject(name, path, withStillsAndLUTs)/GotoRootFolder/GetProjectListInCurrentFolder/GetCurrentProject,
/// Project.GetMediaPool/GetTimelineCount/GetTimelineByIndex/GetCurrentTimeline/SetCurrentTimeline/
/// GetRenderPresetList/LoadRenderPreset/SetRenderSettings(TargetDir, CustomName, SelectAllFrames)/AddRenderJob/
/// StartRendering/IsRenderingInProgress, MediaPool.GetRootFolder/AddSubFolder/SetCurrentFolder/ImportMedia([{FilePath}]),
/// Folder.GetClipList/GetSubFolderList/GetName, MediaPoolItem.GetClipProperty("File Path", "Proxy Media Path",
/// "Frames", "FPS", "Audio Ch", "Start TC", "Type")/GetUniqueId/GetName/LinkProxyMedia/UnlinkProxyMedia/ReplaceClip,
/// Timeline.GetMediaPoolItem/GetNodeGraph/GetTrackCount/GetItemListInTrack, TimelineItem.GetType/GetFusionCompCount/
/// GetFusionCompByIndex/GetEffects("fusion")/GetNodeGraph(layer), Effect.GetFusionComp, Graph.GetNumNodes/GetLUT,
/// Project.GetSetting("nodeStackLayers")/GetColorGroupsList, ColorGroup.GetPre/PostClipNodeGraph; Fusion (fusion_api.pyi):
/// Composition.GetToolList(False)/CopySettings(tools)/MapPath/GetPrefs("Comp"); for the check of what a project reaches
/// also ProjectManager.ExportProject (read back as a .drp), Timeline.DuplicateTimeline, TimelineItem.FlattenMulticam
/// (resolve.FLATTEN_MULTICAM_COPY_GRADE); for the used ranges TimelineItem.GetSourceStartFrame/GetSourceEndFrame/GetDuration.
@MainActor
enum RemoteResolveScript {
    static func run(_ instruction: [String: Any]) async throws -> [String: Any] {
        try await OfficeResolve.run(instruction, script: script)
    }

    static let script = ResolveBridge.preamble + "\n" + #"""
import os

def clips_in(folder):
    found = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        found += clips_in(sub)
    return found

def saved_name(project):
    # Only a real, named project is saved: saving Resolve's empty placeholder opens a dialog that waits.
    return bool(project) and project.GetName() in (pm.GetProjectListInCurrentFolder() or [])

def leave_current(name):
    # Saves what's open, or closes our own copy that is about to be replaced; then the top of the library.
    current = pm.GetCurrentProject()
    if current and current.IsRenderingInProgress():
        out({"error": "busy"})
    if current and current.GetName() == name:
        pm.CloseProject(current)
    elif saved_name(current):
        pm.SaveProject()
    pm.GotoRootFolder()

def fresh(name):
    leave_current(name)
    if name in (pm.GetProjectListInCurrentFolder() or []) and not pm.DeleteProject(name):
        out({"error": "DaVinci Resolve couldn't replace the project " + name + "."})

def binner(pool):
    bins = {(): pool.GetRootFolder()}
    def bin_for(parts):
        key = tuple(parts)
        if key not in bins:
            parent = bin_for(parts[:-1])
            found = next((f for f in (parent.GetSubFolderList() or []) if f.GetName() == parts[-1]), None)
            bins[key] = found or pool.AddSubFolder(parent, parts[-1]) or parent
        return bins[key]
    return bin_for

def timeline_names(project):
    names = []
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t:
            names.append(t.GetName())
    return names

def prop(clip, key):
    value = clip.GetClipProperty(key)
    return "" if value is None else str(value)

# Every file a project reaches beyond its media pool clips (Fusion comps, Fusion effects, LUTs in grades), for the
# host's check (RemoteResolveProject.uses), read twice: through the scripting API (what it reaches, with Fusion's
# path maps) and from the project exported as .drp (everything, also inside compound and multicam clips). A file
# input's value is always a file, any other string that is, or maps to, an absolute path is too; each with its
# tool's regid (the host decides what may be read where). Simple expressions, Lua scripts and Run Command tools
# are passed on. What can't be read goes in "unchecked", and the host refuses it.
# Every other hex blob in the .drp (Fairlight and audio tracks, clips, plugin state) is read as it is, as zlib and as
# zstd, and any absolute path in it (ASCII or UTF-16) is checked as well.
# shortcut: a plugin (OFX, ResolveFX, Fairlight/AU) that keeps a path relative, or in a form other than plain ASCII or
# UTF-16 text inside a blob compressed some other way, isn't seen; the project's own settings (project.xml: cache,
# gallery and proxy folders, written by Resolve itself) aren't checked. Upgrade if such a plugin turns up.
import re, zipfile, zlib, bisect
SCRIPT_KEYS = ("FrameRenderScript", "StartRenderScript", "EndRenderScript", "StartScript", "EndScript",
               "FrameCommand", "StartCommand", "EndCommand", "INPS_ExecuteOnChange", "BTNCS_Execute")
FILE_KEYS = ("Filename", "Clip", "ProxyFilename", "ImportFile", "LUTFile", "OCIOConfig", "ConversionTable", "TemplatePath",
             "MaterialFile", "SoundFilename", "Image")
TEXT_KEYS = ("StyledText", "Comments")
MEDIA_KEYS = ("MEDIA_PATH",)
LUT_ENDINGS = (".cube", ".3dl", ".dctl", ".dctle", ".ilut", ".olut", ".lut", ".csp", ".dat", ".vlt", ".mga", ".m3d", ".itx", ".look", ".clf", ".ctf")

class Notes:
    def __init__(self):
        # (fonts and effects: what the office Mac must have installed, RemoteMissing.)
        self.found = {"refs": [], "expressions": [], "scripts": [], "unchecked": [], "fonts": [], "effects": []}
        self.seen = set()
    def add(self, kind, entry):
        key = (kind,) + tuple(sorted((k, str(v)) for k, v in entry.items()))
        if key not in self.seen:
            self.seen.add(key)
            self.found[kind].append(entry)

def fusion_settings(settings, label, notes, map_path):
    # A Fusion settings table (CopySettings, or a comp read from a .drp); map_path None: path maps aren't known,
    # so a file input that isn't absolute is passed on as it is (and refused), and so is any other mapped-looking path.
    def path_of(text, field):
        is_file = field in FILE_KEYS or field.endswith("Filename") or field.endswith("File")
        if text.startswith("/") or text.startswith("~"):
            return text
        if map_path is None:
            return text if is_file or re.match(r"^[A-Za-z][\w ]*:[^\s]*/", text) else None
        mapped = str(map_path(text) or "")
        if mapped.startswith("/"):
            return mapped
        return text if is_file else None
    def walk(value, tool, regid, field):
        if isinstance(value, dict):
            for k, sub in value.items():
                k = str(k)
                if field == "Tools" and isinstance(sub, dict):
                    sub_regid = str(sub.get("__ctor", ""))
                    if sub_regid == "RunCommand":
                        notes.add("scripts", {"item": label, "tool": k})
                    if sub_regid.startswith("ofx."):
                        notes.add("effects", {"id": sub_regid[4:], "name": k.rstrip("0123456789") or k})
                    inputs = sub.get("Inputs") if isinstance(sub.get("Inputs"), dict) else {}
                    font = input_value(inputs.get("Font"))
                    if font:
                        notes.add("fonts", {"family": font, "style": input_value(inputs.get("Style"))})
                    walk(sub, k, sub_regid, k)
                elif k == "Expression":
                    if str(sub or "").strip():
                        notes.add("expressions", {"item": label, "tool": tool, "text": str(sub)})
                elif k in SCRIPT_KEYS:
                    text = sub.get("Value") if isinstance(sub, dict) else sub
                    if str(text or "").strip():
                        notes.add("scripts", {"item": label, "tool": tool})
                elif k == "__ctor" or (k in TEXT_KEYS and isinstance(sub, str)):
                    continue
                else:
                    # An input's Value (or a list entry) belongs to the input it sits in.
                    walk(sub, tool, regid, field if k == "Value" or k.replace(".", "").isdigit() else k)
        elif isinstance(value, (list, tuple)):
            for sub in value:
                walk(sub, tool, regid, field)
        elif isinstance(value, str) and value.strip() and field not in TEXT_KEYS:
            if field in MEDIA_KEYS:
                notes.add("refs", {"item": label, "tool": tool, "regid": "media", "path": value, "lut": False})
                return
            path = path_of(value, field)
            if path:
                notes.add("refs", {"item": label, "tool": tool, "regid": regid, "path": path, "lut": False})
    walk(settings, "", "", "")

def input_value(value):
    # A Fusion input's plain text value (Input { Value = "…" }), else "".
    value = value.get("Value") if isinstance(value, dict) else value
    return value.strip() if isinstance(value, str) else ""

def fusion_prefs(prefs, label, notes):
    # Comp preferences: only their scripts matter (their paths are the comp's own path maps).
    if isinstance(prefs, dict):
        for k, sub in prefs.items():
            text = sub.get("Value") if isinstance(sub, dict) else sub
            if str(k) in SCRIPT_KEYS and isinstance(text, str) and text.strip():
                notes.add("scripts", {"item": label, "tool": ""})
            else:
                fusion_prefs(sub, label, notes)

LUA_TOKEN = re.compile(r'\s*(?:(--[^\n]*)|("(?:[^"\\]|\\.)*")|([A-Za-z_][\w.]*)|(-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|-?inf|-?nan|-?1\.#\w+)|(.))', re.S)

def lua_table(text):
    # A Fusion settings table as Fusion writes it (strings, numbers, names, Name { … }, [key] = …) as Python dicts,
    # list entries keyed "1", "2"…; anything else (a function, code) raises ValueError.
    tokens = [m for m in LUA_TOKEN.finditer(text) if not m.group(1) and m.group(0).strip()]
    pos = 0
    def peek(n=0):
        return tokens[pos + n] if pos + n < len(tokens) else None
    def take(char=None):
        nonlocal pos
        token = peek()
        if token is None or (char is not None and token.group(5) != char):
            raise ValueError
        pos += 1
        return token
    def string(token):
        body = token.group(2)[1:-1]
        return re.sub(r'\\(\d{1,3}|.)', lambda m: chr(int(m.group(1))) if m.group(1).isdigit() else {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), body)
    def value():
        token = take()
        if token.group(2):
            return string(token)
        if token.group(4):
            return float(token.group(4)) if token.group(4)[-1].isdigit() else 0.0
        if token.group(3):
            name = token.group(3)
            if name in ("true", "false", "nil"):
                return name == "true"
            if peek() is not None and peek().group(5) == "(":
                take("("); take(")")
            if peek() is not None and peek().group(5) == "{":
                table = value()
                table["__ctor"] = name
                return table
            return name
        if token.group(5) == "{":
            table, index = {}, 1
            while peek() is not None and peek().group(5) != "}":
                if peek().group(5) == "[":
                    take("["); key = value(); take("]"); take("=")
                    table[str(key)] = value()
                elif peek().group(3) and peek(1) is not None and peek(1).group(5) == "=":
                    key = take().group(3); take("=")
                    table[key] = value()
                else:
                    table[str(index)] = value(); index += 1
                if peek() is not None and peek().group(5) in (",", ";"):
                    take()
            take("}")
            return table
        raise ValueError
    result = value()
    if pos != len(tokens) or not isinstance(result, dict):
        raise ValueError
    return result

def drp_comp(blob):
    # A <CompositionBA>: 4 length bytes + zlib(a field table with the comp's prefs as Lua, ending
    # "Compressed = true, }" NUL, 4 length bytes + zlib(the comp's tools as Lua)). Returns (prefs, tools).
    outer = zlib.decompress(blob[4:])
    end = outer.find(b"Compressed = true, }\0")
    if end < 0:
        raise ValueError
    start = outer.rfind(b"Composition {", 0, end)
    if start < 0:
        raise ValueError
    prefs = lua_table(outer[start:end + 20].decode("utf-8"))
    tools = zlib.decompress(outer[end + 21 + 4:]).decode("utf-8").strip("\0 \n")
    return prefs, lua_table(tools)

def pb_strings(data, depth=0):
    # Length-delimited fields of a protobuf message, as text when printable and also read as nested messages;
    # None when it isn't one.
    found, i = [], 0
    def varint():
        nonlocal i
        number, shift = 0, 0
        while True:
            if i >= len(data) or shift > 63:
                raise ValueError
            b = data[i]; i += 1
            number |= (b & 0x7f) << shift; shift += 7
            if b < 0x80:
                return number
    try:
        while i < len(data):
            key = varint(); wire = key & 7
            if key >> 3 == 0:
                raise ValueError
            if wire == 0:
                varint()
            elif wire == 1 or wire == 5:
                i += 8 if wire == 1 else 4
            elif wire == 2:
                n = varint(); part = data[i:i + n]; i += n
                if len(part) != n:
                    raise ValueError
                try:
                    text = part.decode("utf-8")
                    if text.isprintable():
                        found.append(text)
                except UnicodeDecodeError:
                    pass
                inner = pb_strings(part, depth + 1) if depth < 20 and part else None
                found += inner or []
            else:
                raise ValueError
            if i > len(data):
                raise ValueError
    except (ValueError, IndexError):
        return None
    return found

def drp_grade(blob):
    # A <Body> grade: one byte, then zstd (Resolve's Python 3.14 has compression.zstd) or a plain protobuf.
    data = blob
    magic = blob.find(b"\x28\xb5\x2f\xfd")
    if 0 <= magic <= 8:
        import compression.zstd
        data = compression.zstd.decompress(blob[magic:])
    strings = pb_strings(data)
    if strings is None:
        raise ValueError
    return strings

def drp_uses(path, notes, label):
    # Everything in an exported project: media paths, every Fusion comp, every grade's LUTs.
    try:
        archive = zipfile.ZipFile(path)
        parts = [(i.filename, archive.read(i).decode("utf-8", "replace")) for i in archive.infolist() if i.filename.endswith(".xml")]
    except Exception:
        notes.add("unchecked", {"item": label, "why": "comp"})
        return
    for part, text in parts:
        # What a blob belongs to: the nearest clip or timeline <Name> before it, else the project.
        names = [(m.start(), xml_text(m.group(1))) for m in re.finditer(r"<Name>([^<]*)</Name>", text)]
        starts = [n[0] for n in names]
        def owner(at):
            i = bisect.bisect(starts, at)
            return names[i - 1][1] if i else label
        # Fonts the project keeps as plain text (subtitle and title styles).
        # shortcut: fonts inside binary blobs (the Edit page's plain Text title) aren't read; upgrade if one turns up.
        for m in re.finditer(r"<(Font|FontName|FontFamily)>([^<]+)</\1>", text):
            notes.add("fonts", {"family": xml_text(m.group(2)).strip(), "style": ""})
        for m in re.finditer(r"<MediaFilePath>([^<]*)</MediaFilePath>", text):
            if m.group(1):
                notes.add("refs", {"item": owner(m.start()), "tool": "", "regid": "media", "path": xml_text(m.group(1)), "lut": False})
        for m in re.finditer(r"<(\w+)>([0-9a-fA-F]{16,})</\1>", text):
            tag, item = m.group(1), owner(m.start())
            if tag == "CompositionBA":
                try:
                    prefs, tools = drp_comp(bytes.fromhex(m.group(2)))
                except Exception:
                    notes.add("unchecked", {"item": item, "why": "comp"})
                    continue
                fusion_prefs(prefs, item, notes)
                fusion_settings({"Tools": tools}, item, notes, None)
            elif tag == "Body":
                try:
                    strings = drp_grade(bytes.fromhex(m.group(2)))
                except Exception:
                    notes.add("unchecked", {"item": item, "why": "grade"})
                    continue
                for s in strings:
                    if s.startswith("/") or s.lower().endswith(LUT_ENDINGS):
                        notes.add("refs", {"item": item, "tool": "LUT", "regid": "", "path": s, "lut": True})
            elif not (part == "project.xml" and tag == "FieldsBlob"):
                for found in blob_paths(bytes.fromhex(m.group(2))):
                    notes.add("refs", {"item": item, "tool": "", "regid": "blob", "path": found, "lut": False})

BLOB_PATH = re.compile(rb"~?/[\x20-\x2e\x30-\x7e]+(?:/[\x20-\x2e\x30-\x7e]+)+")

def blob_paths(blob):
    # Absolute paths (two parts or more) in a blob as it is, inflated (zlib, with or without a 4-byte length) or
    # zstd, as ASCII or UTF-16 text. A blob that decodes no way is still searched as it is.
    forms = [blob]
    for inflate in (lambda: zlib.decompress(blob[4:]), lambda: zlib.decompress(blob)):
        try:
            forms.append(inflate())
        except Exception:
            pass
    magic = blob.find(b"\x28\xb5\x2f\xfd")
    if 0 <= magic <= 16:
        try:
            import compression.zstd
            forms.append(compression.zstd.decompress(blob[magic:]))
        except Exception:
            pass
    found = set()
    for form in forms:
        for text in (form, re.sub(rb"\x00([\x20-\x7e])", rb"\1", form)):
            found.update(p.decode("latin-1") for p in BLOB_PATH.findall(text))
    return sorted(found)

def xml_text(text):
    return text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'").replace("&amp;", "&")

def uses(project, drp=None, drp_label=None):
    notes = Notes()
    def scan_comp(comp, label):
        if comp is None:
            notes.add("unchecked", {"item": label, "why": "comp"})
            return
        try:
            settings = comp.CopySettings(comp.GetToolList(False) or {}) or {}
        except Exception:
            notes.add("unchecked", {"item": label, "why": "comp"})
            return
        fusion_settings(settings, label, notes, comp.MapPath)
        try:
            fusion_prefs(comp.GetPrefs("Comp") or {}, label, notes)
        except Exception:
            notes.add("unchecked", {"item": label, "why": "comp"})
    def scan_graph(graph, label):
        if graph is None:
            return
        for n in range(1, (graph.GetNumNodes() or 0) + 1):
            lut = graph.GetLUT(n)
            if lut:
                notes.add("refs", {"item": label, "tool": "LUT", "regid": "", "path": str(lut), "lut": True})
            try:
                # (Resolve 21's node tooltip: "OFX: name" for a ResolveFX or third-party plugin.)
                for tool in graph.GetToolsInNode(n) or []:
                    if str(tool).startswith("OFX: "):
                        notes.add("effects", {"id": "", "name": str(tool)[5:].strip()})
            except Exception:
                pass
    timelines = [t for t in (project.GetTimelineByIndex(i) for i in range(1, project.GetTimelineCount() + 1)) if t]
    try:
        layers = max(1, int(project.GetSetting("nodeStackLayers") or 1))
    except Exception:
        layers = 1
    for t in timelines:
        try:
            scan_graph(t.GetNodeGraph(), t.GetName())
        except Exception:
            notes.add("unchecked", {"item": t.GetName(), "why": "error"})
        for kind in ("video", "audio"):
            for n in range(1, (t.GetTrackCount(kind) or 0) + 1):
                for it in t.GetItemListInTrack(kind, n) or []:
                    label = it.GetName() or "?"
                    try:
                        if it.GetType() == "transition":
                            continue
                        for c in range(1, (it.GetFusionCompCount() or 0) + 1):
                            scan_comp(it.GetFusionCompByIndex(c), label)
                        for effect in it.GetEffects("fusion") or []:
                            scan_comp(effect.GetFusionComp(), label)
                        for effect in it.GetEffects("ofx") or []:
                            info = effect.GetInfo() or {}
                            if info.get("id") or info.get("name"):
                                notes.add("effects", {"id": str(info.get("id") or ""), "name": str(info.get("name") or "")})
                        if kind == "video":
                            for layer in range(1, layers + 1):
                                scan_graph(it.GetNodeGraph(layer), label)
                    except Exception:
                        notes.add("unchecked", {"item": label, "why": "error"})
    for group in project.GetColorGroupsList() or []:
        try:
            scan_graph(group.GetPreClipNodeGraph(), group.GetName())
            scan_graph(group.GetPostClipNodeGraph(), group.GetName())
        except Exception:
            notes.add("unchecked", {"item": "?", "why": "error"})
    # What the API can't reach (inside compound and multicam clips): the project as Resolve exports it.
    if drp is not None:
        if pm.ExportProject(project.GetName(), drp, False):
            drp_uses(drp, notes, drp_label or project.GetName())
            try:
                os.remove(drp)
            except OSError:
                pass
        else:
            notes.add("unchecked", {"item": drp_label or project.GetName(), "why": "comp"})
    return notes.found

def multicam(item):
    mp = item.GetMediaPoolItem()
    return mp is not None and prop(mp, "Type") == "Multicam"

def flattened(project, title):
    # The timeline to render: a copy with every multicam clip flattened to its active angle (video and audio
    # items each), when it has any; the editor's timeline stays as it was.
    timeline = next((t for t in (project.GetTimelineByIndex(i) for i in range(1, project.GetTimelineCount() + 1)) if t and t.GetName() == title), None)
    def items(t):
        return [it for kind in ("video", "audio") for n in range(1, (t.GetTrackCount(kind) or 0) + 1) for it in t.GetItemListInTrack(kind, n) or []]
    if timeline is None or not any(multicam(it) for it in items(timeline)):
        return title
    names, copy, n = timeline_names(project), title + " (Pluck render)", 2
    while copy in names:
        copy, n = title + " (Pluck render " + str(n) + ")", n + 1
    duplicate = timeline.DuplicateTimeline(copy)
    if not duplicate:
        out({"error": "DaVinci Resolve on the host Mac couldn't copy the timeline to flatten its multicam clips."})
    for kind in ("video", "audio"):
        for n in range(1, (duplicate.GetTrackCount(kind) or 0) + 1):
            for it in duplicate.GetItemListInTrack(kind, n) or []:
                if multicam(it):
                    it.FlattenMulticam(resolve.FLATTEN_MULTICAM_COPY_GRADE)
    if any(multicam(it) for it in items(duplicate)):
        out({"error": "DaVinci Resolve on the host Mac couldn't flatten the multicam clips."})
    return copy

# --- On the host -------------------------------------------------------------------------------

if action == "build":
    # A new project from the originals (bins mirror the folders), each proxy linked, exported as .drp.
    name = cmd["name"]
    fresh(name)
    project = pm.CreateProject(name)
    if project is None:
        out({"error": "DaVinci Resolve on the host Mac couldn't make the project " + name + "."})
    pool = project.GetMediaPool()
    bin_for = binner(pool)
    groups = {}
    for f in cmd["files"]:
        groups.setdefault(tuple(f["bin"]), []).append(f)
    imported, linked, failed = 0, 0, 0
    for key, files in groups.items():
        pool.SetCurrentFolder(bin_for(list(key)))
        items = pool.ImportMedia([{"FilePath": f["path"]} for f in files]) or []
        imported += len(items)
        by_path = {i.GetClipProperty("File Path"): i for i in items}
        for f in files:
            item = by_path.get(f["path"])
            if item is None:
                failed += 1
            elif f.get("proxy") and item.LinkProxyMedia(f["proxy"]):
                linked += 1
    pm.SaveProject()
    if not pm.ExportProject(name, cmd["drp"], False):
        out({"error": "DaVinci Resolve on the host Mac couldn't export the project."})
    out({"imported": imported, "linked": linked, "failed": failed})

if action == "inspect":
    # An editor's project imported under our name: its clips, timelines and the render presets the host
    # had before it (a project can bring its own; only the host's are offered).
    name = cmd["name"]
    fresh(name)
    # The host's presets from an empty project of its own (an open project, even a leftover copy, may carry others).
    import uuid
    scratch = "Pluck – presets – " + uuid.uuid4().hex[:8]
    empty = pm.CreateProject(scratch)
    host_presets = set(empty.GetRenderPresetList() or []) if empty else set()
    if empty:
        pm.CloseProject(empty)
        pm.DeleteProject(scratch)
    if not pm.ImportProject(cmd["drp"], name):
        out({"error": "DaVinci Resolve on the host Mac couldn't import the project."})
    project = pm.LoadProject(name)
    if project is None:
        out({"error": "DaVinci Resolve on the host Mac couldn't open the project."})
    names = timeline_names(project)
    items = []
    for c in clips_in(project.GetMediaPool().GetRootFolder()):
        if prop(c, "File Path") == "" and c.GetName() in names:
            continue  # a timeline (its own items are looked at below)
        items.append({"id": c.GetUniqueId(), "name": c.GetName(), "file": prop(c, "File Path"), "frames": prop(c, "Frames"),
                      "fps": prop(c, "FPS"), "audio": prop(c, "Audio Ch"), "tc": prop(c, "Start TC")})
    render = flattened(project, cmd.get("timeline", ""))
    pm.SaveProject()
    found = uses(project, cmd["drp"] + ".check.drp", cmd.get("label"))
    try:
        installed = [{"id": str(e.get("id") or ""), "name": str(e.get("name") or "")}
                     for kind in ("video", "audio") for e in (resolve.GetEffectsList(kind) or [])]
    except Exception:
        installed = None
    found.update({"items": items, "timelines": names, "render": render, "installed": installed,
                  "presets": [p for p in (project.GetRenderPresetList() or []) if p in host_presets]})
    out(found)

if action == "render":
    # Proxies swapped for their originals (by media pool id), then one render with the preset.
    name = cmd["name"]
    project = pm.GetCurrentProject()
    if project is None or project.GetName() != name:
        leave_current("")
        project = pm.LoadProject(name)
        if project is None:
            out({"error": "DaVinci Resolve on the host Mac couldn't open the project."})
    if project.IsRenderingInProgress():
        out({"error": "busy"})
    swaps = cmd["swaps"]
    failed = []
    for c in clips_in(project.GetMediaPool().GetRootFolder()):
        target = swaps.get(c.GetUniqueId())
        if target:
            c.UnlinkProxyMedia()
            if not c.ReplaceClip(target):
                failed.append(c.GetName())
    if failed:
        out({"error": "DaVinci Resolve couldn't switch to the originals of: " + ", ".join(failed[:5])})
    pm.SaveProject()
    timeline = None
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t and t.GetName() == cmd["timeline"]:
            timeline = t
    if timeline is None:
        out({"error": "The timeline " + cmd["timeline"] + " isn't in this project."})
    project.SetCurrentTimeline(timeline)
    if not project.LoadRenderPreset(cmd["preset"]):
        out({"error": "The render preset " + cmd["preset"] + " couldn't be loaded on the host Mac."})
    os.makedirs(cmd["target"], exist_ok=True)
    project.SetRenderSettings({"SelectAllFrames": True, "TargetDir": cmd["target"], "CustomName": cmd["output"]})
    job = project.AddRenderJob()
    if not job:
        out({"error": "DaVinci Resolve couldn't add the render job (check the preset's settings)."})
    if not project.StartRendering([job], False):
        project.DeleteRenderJob(job)
        out({"error": "DaVinci Resolve couldn't start rendering."})
    out({"job": job})

if action == "uses":
    # What the open project reaches, as "inspect" sees it (Pluck's resolveuses self-test); only exports a copy.
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    import tempfile
    found = uses(project, os.path.join(tempfile.gettempdir(), "pluck-uses-" + str(os.getpid()) + ".drp"))
    found["project"] = project.GetName()
    found["items"] = [{"file": prop(c, "File Path")} for c in clips_in(project.GetMediaPool().GetRootFolder())]
    found["files"] = sorted(set(prop(c, "File Path") for c in clips_in(project.GetMediaPool().GetRootFolder())) - {""})
    found["types"] = sorted(set(prop(c, "Type") for c in clips_in(project.GetMediaPool().GetRootFolder())))
    out(found)

if action == "effects":
    # The effects (ResolveFX, OFX and audio plugins) this Resolve has, for RemoteMissing's check.
    out({"effects": [{"id": str(e.get("id") or ""), "name": str(e.get("name") or "")}
                     for kind in ("video", "audio") for e in (resolve.GetEffectsList(kind) or [])]})

if action == "presets":
    project = pm.GetCurrentProject()
    out({"presets": list(project.GetRenderPresetList() or []) if project else []})

# --- On the editor's Mac -----------------------------------------------------------------------

if action == "current":
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    current = project.GetCurrentTimeline()
    files = sorted(set(prop(c, "File Path") for c in clips_in(project.GetMediaPool().GetRootFolder())) - {""})
    out({"project": project.GetName(), "saved": saved_name(project), "timelines": timeline_names(project),
         "timeline": current.GetName() if current else None, "files": files})

if action == "export":
    project = pm.GetCurrentProject()
    if not saved_name(project):
        out({"error": "Save the project in DaVinci Resolve first."})
    pm.SaveProject()
    if not pm.ExportProject(project.GetName(), cmd["drp"], False):
        out({"error": "DaVinci Resolve couldn't export the project."})
    out({"project": project.GetName()})

if action == "open":
    # A project from the host, imported under a free name and opened.
    current = pm.GetCurrentProject()
    if saved_name(current):
        pm.SaveProject()
    names = pm.GetProjectListInCurrentFolder() or []
    name, n = cmd["name"], 2
    while name in names:
        name, n = cmd["name"] + " " + str(n), n + 1
    if not pm.ImportProject(cmd["drp"], name):
        out({"error": "DaVinci Resolve couldn't import the project."})
    if pm.LoadProject(name) is None:
        out({"error": "DaVinci Resolve couldn't open the project."})
    out({"project": name})

if action == "ranges":
    # The source frames each file is used for on the timeline (current, or cmd["timeline"]), to pull only those parts.
    # A retimed item (its length differs from its source span) takes the whole clip. Files inside compound and
    # multicam clips come from the exported project and are taken whole; if none can be matched to them, every media
    # file of the project is (never guess).
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    timeline = project.GetCurrentTimeline()
    if cmd.get("timeline"):
        timeline = next((t for t in (project.GetTimelineByIndex(i) for i in range(1, project.GetTimelineCount() + 1)) if t and t.GetName() == cmd["timeline"]), None)
    if timeline is None:
        out({"error": "No timeline is open in DaVinci Resolve."})
    items, nested = [], set()
    for kind in ("video", "audio"):
        for n in range(1, (timeline.GetTrackCount(kind) or 0) + 1):
            for it in timeline.GetItemListInTrack(kind, n) or []:
                mp = it.GetMediaPoolItem()
                if mp is None:
                    continue
                path = prop(mp, "File Path")
                if not path:
                    nested.add(it.GetName() or mp.GetName())
                    continue
                try:
                    start, end = int(it.GetSourceStartFrame()), int(it.GetSourceEndFrame())
                    retimed = abs(abs(end - start) - float(it.GetDuration())) > 1
                except Exception:
                    start, end, retimed = 0, 0, True
                items.append({"file": path, "start": start, "end": end, "retimed": retimed})
    whole = []
    if nested:
        import tempfile
        drp = os.path.join(tempfile.gettempdir(), "pluck-ranges-" + str(os.getpid()) + ".drp")
        notes = Notes()
        if pm.ExportProject(project.GetName(), drp, False):
            drp_uses(drp, notes, project.GetName())
            try:
                os.remove(drp)
            except OSError:
                pass
        media = [r for r in notes.found["refs"] if r.get("regid") == "media"]
        inside = [r["path"] for r in media if r.get("item") in nested]
        whole = sorted(set(inside or [r["path"] for r in media]))
    out({"items": items, "whole": whole, "timeline": timeline.GetName(), "nested": sorted(nested)})

if action == "link":
    # Clips of the host's originals get their local proxy linked; proxies not in the project yet are
    # imported into a bin per shared folder. Matched by full path, never by name.
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    pool = project.GetMediaPool()
    by_file = {}
    for c in clips_in(pool.GetRootFolder()):
        by_file.setdefault(prop(c, "File Path"), []).append(c)
    linked, added, present, failed = 0, 0, 0, 0
    pending = {}
    for e in cmd["entries"]:
        originals = by_file.get(e.get("original") or "", [])
        if originals:
            for c in originals:
                if prop(c, "Proxy Media Path") == e["proxy"] or c.LinkProxyMedia(e["proxy"]):
                    linked += 1
                else:
                    failed += 1
        elif e["proxy"] in by_file:
            present += 1
        else:
            pending.setdefault(tuple(e["bin"]), []).append(e["proxy"])
    bin_for = binner(pool)
    for key, files in pending.items():
        pool.SetCurrentFolder(bin_for(list(key)))
        items = pool.ImportMedia([{"FilePath": f} for f in files]) or []
        added += len(items)
        failed += len(files) - len(items)
    if saved_name(project):
        pm.SaveProject()
    out({"linked": linked, "added": added, "present": present, "failed": failed})

out({"error": "Unknown action " + action})
"""#
}
