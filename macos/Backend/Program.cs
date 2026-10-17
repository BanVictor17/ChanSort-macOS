using System.Reflection;
using System.Text;
using System.Text.Json;
using ChanSort.Api;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
Console.InputEncoding = Console.OutputEncoding = new UTF8Encoding(false);
var root = Environment.GetEnvironmentVariable("CHANSORT_HOME") ?? AppContext.BaseDirectory;
Directory.CreateDirectory(Path.Combine(root, "tmp"));
Environment.SetEnvironmentVariable("TMPDIR", Path.Combine(root, "tmp"));
var engine = new Engine(root);
View.Default = new View {
  MessageBoxImpl = (message, caption, buttons, icon) => {
    var options = buttons switch {
      View.MessageBoxButtons.YesNo => new[] {("Yes", (int)View.DialogResult.Yes), ("No", (int)View.DialogResult.No)},
      View.MessageBoxButtons.YesNoCancel => new[] {("Yes", (int)View.DialogResult.Yes), ("No", (int)View.DialogResult.No), ("Cancel", (int)View.DialogResult.Cancel)},
      View.MessageBoxButtons.OK => new[] {("OK", (int)View.DialogResult.OK)},
      _ => new[] {("OK", (int)View.DialogResult.OK), ("Cancel", (int)View.DialogResult.Cancel)}
    };
    return (View.DialogResult)Engine.Prompt(caption, message, options);
  },
  ShowHtmlBoxImpl = (html, title, w, h, callback) => Engine.Prompt(title ?? "ChanSort", System.Text.RegularExpressions.Regex.Replace(html, "<[^>]+>", ""), new[] {("OK", 1)}),
  CreateActionBox = title => new NativeActionBox(title)
};
string line;
while ((line = Console.ReadLine()) != null) {
  try {
    using var doc = JsonDocument.Parse(line);
    Engine.Send(engine.Handle(doc.RootElement));
  } catch (Exception ex) { Console.Error.WriteLine(ex); Engine.Send(new { type = "error", message = ex.Message }); }
}
engine.Dispose();

sealed class NativeActionBox(string title) : IActionBoxDialog {
  public string Message { get; set; } = "";
  readonly List<(string, int)> actions = new();
  public int SelectedAction { get; private set; }
  public void AddAction(string text, int result) => actions.Add((text, result));
  public void ShowDialog() => SelectedAction = Engine.Prompt(title, Message, actions.ToArray());
  public void Dispose() { }
}
sealed class Engine(string root) : IDisposable {
  SerializerBase serializer;
  ChannelList[] lists = [];
  public static void Send(object value) { Console.WriteLine(JsonSerializer.Serialize(value)); Console.Out.Flush(); }
  public static int Prompt(string title, string message, (string text, int result)[] actions) {
    Send(new { type = "prompt", title, message, actions = actions.Select(a => new { text = a.text, result = a.result }) });
    using var answer = JsonDocument.Parse(Console.ReadLine() ?? throw new Exception("UI disconnected"));
    return answer.RootElement.GetProperty("result").GetInt32();
  }
  public object Handle(JsonElement req) {
    switch (req.GetProperty("command").GetString()) {
      case "plugins": return new { type = "plugins", plugins = Plugins().Select(p => p.PluginName).ToArray() };
      case "load": return Load(req.GetProperty("path").GetString());
      case "save": return Save(req);
      default: throw new Exception("Unknown command");
    }
  }
  static IEnumerable<ISerializerPlugin> Plugins() {
    foreach (var file in Directory.GetFiles(AppContext.BaseDirectory, "ChanSort.Loader.*.dll").OrderBy(x => x)) {
      var assembly = Assembly.LoadFrom(file);
      foreach (var t in assembly.GetTypes().Where(t => !t.IsAbstract && typeof(ISerializerPlugin).IsAssignableFrom(t))) {
        var p = (ISerializerPlugin)Activator.CreateInstance(t); p.DllName = file; yield return p;
      }
    }
    yield return new RefSerializerPlugin();
  }
  object Load(string path) {
    serializer?.Dispose(); serializer = null;
    var errors = new List<string>();
    foreach (var plugin in Plugins().Where(p => p.FileFilter.Split(';').Any(f => System.IO.Enumeration.FileSystemName.MatchesSimpleExpression(f.Trim(), Path.GetFileName(path), true)))) {
      SerializerBase attempt = null;
      try {
        attempt = plugin.CreateSerializer(path);
        if (attempt == null) continue;
        attempt.Load();
        attempt.DataRoot.ValidateAfterLoad();
        attempt.DataRoot.ApplyCurrentProgramNumbers();
        serializer = attempt;
        lists = serializer.DataRoot.ChannelLists.Where(l => l.Count > 0).ToArray();
        return Snapshot();
      } catch (ChanSort.LoaderException ex) {
        attempt?.Dispose(); errors.Add(plugin.PluginName + ": " + ex.Message);
        if (ex.Recovery == ChanSort.LoaderException.RecoveryMode.Fail) throw;
      } catch (Exception ex) { attempt?.Dispose(); errors.Add(plugin.PluginName + ": " + ex.Message); }
    }
    throw new Exception("Unable to open this export.\n" + string.Join("\n", errors));
  }
  object Snapshot() => new {
    type = "loaded", path = serializer.FileName, warnings = serializer.DataRoot.Warnings.ToString(),
    lists = lists.Select((l, li) => new {
      id = li, name = l.ShortCaption, readOnly = l.ReadOnly || l.IsMixedSourceFavoritesList,
      channels = l.Channels.Select((c, ci) => new { id = ci, number = c.NewProgramNr, oldNumber = c.OldProgramNr, name = c.Name, source = c.SignalSource.ToString(), deleted = c.IsDeleted })
    })
  };
  object Save(JsonElement req) {
    if (serializer == null) throw new Exception("Open an export first.");
    // Validate the entire request before mutating any channel.
    var changes = new List<(ChannelInfo channel, int number)>();
    foreach (var input in req.GetProperty("lists").EnumerateArray()) {
      int id = input.GetProperty("id").GetInt32();
      if (id < 0 || id >= lists.Length) throw new Exception("Invalid list.");
      var list = lists[id];
      if (list.ReadOnly || list.IsMixedSourceFavoritesList) continue;
      var rows = input.GetProperty("channels").EnumerateArray().ToArray();
      if (rows.Length != list.Channels.Count) throw new Exception("Incomplete channel list.");
      var ids = new HashSet<int>(); var numbers = new HashSet<int>();
      foreach (var row in rows) {
        int ci = row.GetProperty("id").GetInt32(), nr = row.GetProperty("number").GetInt32();
        if (ci < 0 || ci >= list.Count || !ids.Add(ci)) throw new Exception("Invalid channel.");
        var c = list.Channels[ci];
        if (c.IsDeleted || c.OldProgramNr < 0) continue;
        if (nr < 0 || nr > 65534 || !numbers.Add(nr)) throw new Exception("Channel numbers must be unique and between 0 and 65534.");
        changes.Add((c, nr));
      }
    }
    var files = serializer.GetDataFilePaths().Where(File.Exists).Select(Path.GetFullPath).Distinct().ToArray();
    if (files.Length == 0) throw new Exception("No source files available for backup.");
    var backup = Path.Combine(root, "backups", DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
    Directory.CreateDirectory(backup);
    var saved = new List<(string original, string copy)>();
    foreach (var file in files) {
      var copy = Path.Combine(backup, saved.Count.ToString("D3") + "-" + Path.GetFileName(file));
      File.Copy(file, copy); saved.Add((file, copy));
    }
    File.WriteAllText(Path.Combine(backup, "manifest.json"), JsonSerializer.Serialize(saved.Select(x => new { original = x.original, backup = x.copy })));
    var previous = changes.Select(c => c.channel.NewProgramNr).ToArray();
    try {
      foreach (var change in changes) change.channel.NewProgramNr = change.number;
      serializer.Save();
      serializer.DataRoot.ValidateAfterSave();
    } catch {
      foreach (var entry in saved) File.Copy(entry.copy, entry.original, true);
      for (int i=0;i<changes.Count;i++) changes[i].channel.NewProgramNr = previous[i];
      throw;
    }
    return new { type = "saved", backup };
  }
  public void Dispose() => serializer?.Dispose();
}
