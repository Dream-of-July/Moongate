namespace Moongate.Core;

public enum QueueProgressPhase
{
    Download = 0,
    Transcode = 1,
    Translate = 2,
    Burn = 3,
    ModelDownload = 4,
    AudioExtract = 5,
    SpeechRecognition = 6,
    SubtitleSegment = 7,
}

public sealed record QueueProgressPlan
{
    public IReadOnlyList<QueueProgressPhase> Phases { get; }

    public QueueProgressPlan(bool shouldTranscode, bool shouldTranslate, bool shouldBurn)
    {
        var phases = new List<QueueProgressPhase> { QueueProgressPhase.Download };
        if (shouldTranscode) phases.Add(QueueProgressPhase.Transcode);
        if (shouldTranslate) phases.Add(QueueProgressPhase.Translate);
        if (shouldBurn) phases.Add(QueueProgressPhase.Burn);
        Phases = phases;
    }
}

public readonly record struct TaskWorkPhase
{
    public QueueProgressPhase Phase { get; init; }
    public double Units { get; init; }

    public TaskWorkPhase(QueueProgressPhase phase, double units)
    {
        Phase = phase;
        Units = Math.Max(0, units);
    }
}

public sealed record TaskWorkPlan
{
    public IReadOnlyList<TaskWorkPhase> Phases { get; }

    public double TotalUnits => Phases.Sum(phase => phase.Units);

    public TaskWorkPlan(IEnumerable<TaskWorkPhase> phases)
    {
        Phases = phases.Where(phase => phase.Units > 0).ToList();
    }

    public TaskWorkPlan(QueueProgressPlan queuePlan)
        : this(queuePlan.Phases.Select(phase => new TaskWorkPhase(phase, units: 1)))
    {
    }

    public TaskWorkPlan(
        bool shouldDownloadModel = false,
        bool shouldExtractAudio = false,
        bool shouldRunASR = false,
        bool shouldSegmentSubtitles = false,
        bool shouldTranscode = false,
        bool shouldTranslate = false,
        bool shouldBurn = false,
        double modelDownloadUnits = 1,
        double downloadUnits = 1,
        double audioExtractUnits = 1,
        double speechRecognitionUnits = 1,
        double subtitleSegmentUnits = 1,
        double transcodeUnits = 1,
        double translateUnits = 1,
        double burnUnits = 1)
        : this(BuildPhases(
            shouldDownloadModel,
            shouldExtractAudio,
            shouldRunASR,
            shouldSegmentSubtitles,
            shouldTranscode,
            shouldTranslate,
            shouldBurn,
            modelDownloadUnits,
            downloadUnits,
            audioExtractUnits,
            speechRecognitionUnits,
            subtitleSegmentUnits,
            transcodeUnits,
            translateUnits,
            burnUnits))
    {
    }

    private static IEnumerable<TaskWorkPhase> BuildPhases(
        bool shouldDownloadModel,
        bool shouldExtractAudio,
        bool shouldRunASR,
        bool shouldSegmentSubtitles,
        bool shouldTranscode,
        bool shouldTranslate,
        bool shouldBurn,
        double modelDownloadUnits,
        double downloadUnits,
        double audioExtractUnits,
        double speechRecognitionUnits,
        double subtitleSegmentUnits,
        double transcodeUnits,
        double translateUnits,
        double burnUnits)
    {
        if (shouldDownloadModel) yield return new TaskWorkPhase(QueueProgressPhase.ModelDownload, modelDownloadUnits);
        yield return new TaskWorkPhase(QueueProgressPhase.Download, downloadUnits);
        if (shouldExtractAudio) yield return new TaskWorkPhase(QueueProgressPhase.AudioExtract, audioExtractUnits);
        if (shouldRunASR) yield return new TaskWorkPhase(QueueProgressPhase.SpeechRecognition, speechRecognitionUnits);
        if (shouldSegmentSubtitles) yield return new TaskWorkPhase(QueueProgressPhase.SubtitleSegment, subtitleSegmentUnits);
        if (shouldTranscode) yield return new TaskWorkPhase(QueueProgressPhase.Transcode, transcodeUnits);
        if (shouldTranslate) yield return new TaskWorkPhase(QueueProgressPhase.Translate, translateUnits);
        if (shouldBurn) yield return new TaskWorkPhase(QueueProgressPhase.Burn, burnUnits);
    }
}

public readonly record struct RemainingEstimate(double Seconds, bool IsApproximate);

public readonly record struct TaskProgressSnapshot(
    double? OverallProgress,
    double? RemainingSeconds,
    bool IsEstimatingRemaining,
    bool IsTerminal)
{
    public QueueProgressPlan? Plan { get; init; }
    public TaskWorkPlan? WorkPlan { get; init; }
    public QueueProgressPhase? CurrentPhase { get; init; }

    public TaskProgressSnapshot(
        double? OverallProgress,
        double? RemainingSeconds,
        bool IsEstimatingRemaining,
        bool IsTerminal,
        QueueProgressPlan? Plan,
        QueueProgressPhase? CurrentPhase,
        TaskWorkPlan? WorkPlan = null)
        : this(OverallProgress, RemainingSeconds, IsEstimatingRemaining, IsTerminal)
    {
        this.Plan = Plan;
        this.WorkPlan = WorkPlan;
        this.CurrentPhase = CurrentPhase;
    }
}

public readonly record struct QueueProgressSnapshot(
    double OverallProgress,
    double? RemainingSeconds,
    bool IsEstimatingRemaining);

public static class QueueProgressEstimator
{
    public static double? NormalizedFraction(double? value)
    {
        if (value is not { } number || double.IsNaN(number) || double.IsInfinity(number)) return null;
        return Math.Clamp(number, 0, 1);
    }

    public static double? TaskOverallProgress(
        QueueProgressPlan plan,
        QueueProgressPhase? currentPhase,
        double? phaseProgress,
        double? previousOverallProgress)
    {
        return TaskOverallProgress(
            new TaskWorkPlan(plan),
            currentPhase,
            phaseProgress,
            previousOverallProgress);
    }

    public static double? TaskOverallProgress(
        TaskWorkPlan workPlan,
        QueueProgressPhase? currentPhase,
        double? phaseProgress,
        double? previousOverallProgress)
    {
        if (workPlan.TotalUnits <= 0) return previousOverallProgress;
        if (currentPhase is not { } phase) return previousOverallProgress;
        var index = -1;
        for (var i = 0; i < workPlan.Phases.Count; i++)
        {
            if (workPlan.Phases[i].Phase == phase)
            {
                index = i;
                break;
            }
        }
        if (index < 0) return previousOverallProgress;

        var current = NormalizedFraction(phaseProgress) ?? 0;
        var completedUnits = workPlan.Phases.Take(index).Sum(item => item.Units);
        var computed = (completedUnits + current * workPlan.Phases[index].Units) / workPlan.TotalUnits;
        var previous = NormalizedFraction(previousOverallProgress);
        return previous is { } p ? Math.Max(p, computed) : computed;
    }

    public static double? ParseEtaSeconds(string? text)
    {
        var raw = (text ?? "").Trim();
        if (raw.Length == 0 || raw == "N/A" || raw == "Unknown") return null;
        var parts = raw.Split(':');
        if (parts.Length is not (2 or 3)) return null;
        var total = 0;
        foreach (var part in parts)
        {
            if (!int.TryParse(part, out var value)) return null;
            total = total * 60 + value;
        }
        return total;
    }

    public static RemainingEstimate? EstimatedRemainingSeconds(
        double elapsedSeconds,
        double? phaseProgress,
        double? sourceEtaSeconds,
        double minimumElapsedSeconds = 3,
        double minimumProgress = 0.03)
    {
        if (sourceEtaSeconds is { } source && !double.IsNaN(source) && !double.IsInfinity(source) && source >= 0)
        {
            return new RemainingEstimate(source, IsApproximate: false);
        }
        if (elapsedSeconds < minimumElapsedSeconds) return null;
        var progress = NormalizedFraction(phaseProgress);
        if (progress is not { } p || p < minimumProgress || p >= 1) return null;
        var remaining = elapsedSeconds * (1 - p) / p;
        if (double.IsNaN(remaining) || double.IsInfinity(remaining) || remaining < 0) return null;
        return new RemainingEstimate(remaining, IsApproximate: true);
    }

    public static QueueProgressSnapshot QueueSnapshot(
        IReadOnlyList<TaskProgressSnapshot> items,
        IReadOnlyDictionary<QueueProgressPhase, double>? phaseMedianDurations = null,
        IReadOnlyDictionary<QueueProgressPhase, int>? phaseCapacities = null)
    {
        if (items.Count == 0) return new QueueProgressSnapshot(0, null, false);

        var total = 0.0;
        foreach (var item in items)
        {
            if (item.IsTerminal)
            {
                total += NormalizedFraction(item.OverallProgress) ?? 1;
            }
            else
            {
                total += NormalizedFraction(item.OverallProgress) ?? 0;
            }
        }

        var overall = Math.Clamp(total / items.Count, 0, 1);
        var open = items.Where(item => !item.IsTerminal).ToList();
        if (!open.Any(item => item.Plan is not null || item.WorkPlan is not null))
        {
            var remaining = open
                .Select(item => item.RemainingSeconds)
                .Where(value => ValidSeconds(value) is not null)
                .DefaultIfEmpty(null)
                .Max();
            var estimating = open.Any(item => item.IsEstimatingRemaining);
            return new QueueProgressSnapshot(overall, remaining, estimating);
        }

        phaseMedianDurations ??= new Dictionary<QueueProgressPhase, double>();
        phaseCapacities ??= new Dictionary<QueueProgressPhase, int>();
        var phaseWork = new Dictionary<QueueProgressPhase, double>();
        var longestTaskRemaining = 0.0;
        var hasUnknownWork = false;

        foreach (var item in open)
        {
            var taskRemaining = 0.0;
            var workPlan = item.WorkPlan ?? (item.Plan is { } queuePlan ? new TaskWorkPlan(queuePlan) : null);
            if (workPlan is null)
            {
                if (ValidSeconds(item.RemainingSeconds) is { } seconds)
                {
                    AddWork(phaseWork, item.CurrentPhase ?? QueueProgressPhase.Download, seconds);
                    taskRemaining += seconds;
                }
                else if (item.IsEstimatingRemaining)
                {
                    hasUnknownWork = true;
                }
                longestTaskRemaining = Math.Max(longestTaskRemaining, taskRemaining);
                continue;
            }

            int nextIndex;
            if (item.CurrentPhase is { } currentPhase)
            {
                var index = workPlan.Phases.ToList().FindIndex(item => item.Phase == currentPhase);
                if (index >= 0)
                {
                    if (ValidSeconds(item.RemainingSeconds) is { } seconds)
                    {
                        AddWork(phaseWork, currentPhase, seconds);
                        taskRemaining += seconds;
                    }
                    else
                    {
                        hasUnknownWork = true;
                    }
                    nextIndex = index + 1;
                }
                else
                {
                    nextIndex = CompletedPhaseCount(workPlan, NormalizedFraction(item.OverallProgress) ?? 0);
                }
            }
            else
            {
                nextIndex = CompletedPhaseCount(workPlan, NormalizedFraction(item.OverallProgress) ?? 0);
            }

            for (var i = nextIndex; i < workPlan.Phases.Count; i++)
            {
                var phase = workPlan.Phases[i];
                if (phaseMedianDurations.TryGetValue(phase.Phase, out var secondsPerUnit) && ValidSeconds(secondsPerUnit) is { } valid)
                {
                    var seconds = valid * phase.Units;
                    AddWork(phaseWork, phase.Phase, seconds);
                    taskRemaining += seconds;
                }
                else
                {
                    hasUnknownWork = true;
                }
            }
            longestTaskRemaining = Math.Max(longestTaskRemaining, taskRemaining);
        }

        if (hasUnknownWork) return new QueueProgressSnapshot(overall, null, true);

        double? phaseBound = phaseWork.Count == 0
            ? null
            : phaseWork.Max(kv =>
            {
                var capacity = phaseCapacities.TryGetValue(kv.Key, out var value) ? Math.Max(1, value) : 1;
                return kv.Value / capacity;
            });
        var queueRemaining = Math.Max(phaseBound ?? 0, longestTaskRemaining);
        return new QueueProgressSnapshot(overall, queueRemaining > 0 ? queueRemaining : null, false);
    }

    private static double? ValidSeconds(double? value)
    {
        if (value is not { } number || double.IsNaN(number) || double.IsInfinity(number) || number < 0) return null;
        return number;
    }

    private static int CompletedPhaseCount(TaskWorkPlan plan, double overallProgress)
    {
        var completedUnits = overallProgress * plan.TotalUnits;
        var running = 0.0;
        var count = 0;
        foreach (var phase in plan.Phases)
        {
            if (running + phase.Units > completedUnits + 0.0001) break;
            running += phase.Units;
            count++;
        }
        return Math.Clamp(count, 0, plan.Phases.Count);
    }

    private static void AddWork(Dictionary<QueueProgressPhase, double> work, QueueProgressPhase phase, double seconds)
    {
        work[phase] = work.GetValueOrDefault(phase) + seconds;
    }
}
