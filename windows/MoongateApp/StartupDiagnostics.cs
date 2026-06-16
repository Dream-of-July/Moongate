using System.IO;
using System.Text;
using Moongate.Core;

namespace Moongate.App;

/// <summary>
/// 启动期诊断日志：把启动里程碑与未捕获异常落盘到 %APPDATA%\Moongate\startup.log，
/// 让「安装后白屏 / 无窗口」这类只在部分机器复现、且界面起不来的问题能被用户回传排查。
///
/// 设计要点：
/// - 任何写日志失败都被吞掉（诊断设施绝不能反过来把启动搞崩）。
/// - 不写任何凭证/隐私，只写时间戳、阶段名、异常类型与消息、运行环境摘要。
/// - 单文件，超过上限就截断重建，避免无限增长。
/// </summary>
public static class StartupDiagnostics
{
    private const long MaxLogBytes = 256 * 1024;

    private static string LogPath
    {
        get
        {
            try
            {
                return Path.Combine(AppSettings.SupportDirectory, "startup.log");
            }
            catch
            {
                // SupportDirectory 解析失败时退到临时目录，仍尽量留下线索。
                return Path.Combine(Path.GetTempPath(), "Moongate-startup.log");
            }
        }
    }

    /// <summary>记录一个启动阶段里程碑（如 "OnStartup begin" / "MainWindow shown"）。</summary>
    public static void Mark(string stage) => Write($"[stage] {stage}");

    /// <summary>记录一次异常（阶段名 + 异常全文，含内层异常）。</summary>
    public static void RecordException(string stage, Exception error)
    {
        var sb = new StringBuilder();
        sb.Append("[error] ").Append(stage).Append(": ");
        var current = error;
        var depth = 0;
        while (current is not null && depth < 5)
        {
            if (depth > 0) sb.Append(" <- ");
            sb.Append(current.GetType().FullName).Append(": ").Append(current.Message);
            current = current.InnerException;
            depth++;
        }
        Write(sb.ToString());
        // 堆栈单独成行，便于阅读。
        Write("[stack] " + (error.StackTrace ?? "(no stack)"));
    }

    /// <summary>写一次运行环境摘要，便于区分「部分机器」差异（OS / 架构 / 渲染层）。</summary>
    public static void RecordEnvironment(int renderTier)
    {
        try
        {
            var summary = string.Join(
                "; ",
                $"os={Environment.OSVersion}",
                $"arch={System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}",
                $"procArch={System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}",
                $"clr={Environment.Version}",
                $"renderTier={renderTier}",
                $"culture={System.Globalization.CultureInfo.CurrentUICulture.Name}");
            Write("[env] " + summary);
        }
        catch
        {
            // 环境摘要失败不影响其它日志。
        }
    }

    private static void Write(string line)
    {
        try
        {
            var path = LogPath;
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            // 超限就重置，防止日志无限增长。
            try
            {
                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    File.Delete(path);
                }
            }
            catch
            {
                // 大小检查失败忽略，继续追加。
            }
            File.AppendAllText(path, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz} {line}{Environment.NewLine}");
        }
        catch
        {
            // 诊断设施绝不能把启动搞崩：任何写失败都静默忽略。
        }
    }
}
