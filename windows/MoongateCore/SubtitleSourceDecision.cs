namespace Moongate.Core;

public enum SubtitleAsrTrigger
{
    Never,
    FallbackOnly,
    ExplicitCompare,
    ExplicitForce,
}

public enum SubtitleSourceDecisionCandidateStatus
{
    Selected,
    Backup,
    NotUsed,
    Unavailable,
}

public enum SubtitleSourceDecisionReason
{
    ImportedSubtitleExplicit,
    ManualMatchesVideoLanguage,
    ManualMatchesUserLanguage,
    ManualMatchesInferredLanguage,
    PlatformSubtitleMatchesVideoLanguage,
    PlatformSubtitleMatchesUserLanguage,
    PlatformSubtitleMatchesInferredLanguage,
    PlatformAutoMatchesVideoLanguage,
    PlatformAutoMatchesUserLanguage,
    PlatformAutoMatchesInferredLanguage,
    TargetLanguageSubtitleNotSource,
    ManualLanguageMismatch,
    PlatformLanguageMismatch,
    LocalRecognitionFallbackOnly,
    LocalRecognitionForced,
    CompareRequested,
    CloudRecognitionForced,
    CloudRecognitionUnavailable,
    NoTrustedPlatformSubtitle,
    NoUsableSubtitleSource,
}

public enum SubtitleSourceLanguageEvidence
{
    UserPreference,
    Metadata,
    TitleScript,
    Unavailable,
}

public enum SubtitleSourceLanguageConfidence
{
    High,
    Medium,
    Low,
    Unknown,
}

public sealed record SubtitleSourceDecisionCandidateReport(
    string TrackId,
    SubtitleSourceKind SourceKind,
    string LanguageCode,
    string Label,
    SubtitleSourceDecisionCandidateStatus Status,
    SubtitleSourceDecisionReason Reason);

public sealed record SubtitleSourceDecisionReport(
    SubtitleChoice? SelectedTrack,
    IReadOnlyList<SubtitleSourceDecisionCandidateReport> CandidateReports,
    SubtitleAsrTrigger AsrTrigger,
    SubtitleSourceDecisionReason UserFacingReason,
    SubtitleSourceDecisionReason DiagnosticReason,
    string? SourceLanguageCode,
    SubtitleSourceLanguageEvidence SourceLanguageEvidence,
    SubtitleSourceLanguageConfidence SourceLanguageConfidence);

public static class SubtitleSourceDecision
{
    private sealed record Selection(
        SubtitleChoice? Track,
        SubtitleSourceDecisionReason Reason,
        SubtitleAsrTrigger AsrTrigger);

    public static SubtitleSourceDecisionReport Decide(
        string videoTitle,
        string? detectedLanguageCode,
        string? targetLanguageCode,
        string? preferredSourceLanguageCode,
        SubtitleSourcePolicy sourcePolicy,
        IReadOnlyList<SubtitleChoice> choices,
        bool localAsrAvailable,
        bool cloudAsrAvailable)
    {
        var explicitSourceLanguage = NormalizedExplicitSourceLanguage(preferredSourceLanguageCode);
        var metadataLanguage = NormalizedLanguage(detectedLanguageCode);
        var titleLanguage = explicitSourceLanguage is null && metadataLanguage is null
            ? NormalizedLanguage(SubtitleLanguageRecommender.InferredLocalAsrLanguageCode(videoTitle))
            : null;
        var sourceLanguageCode = explicitSourceLanguage ?? metadataLanguage ?? titleLanguage;
        SubtitleSourceLanguageEvidence evidence;
        SubtitleSourceLanguageConfidence confidence;
        if (explicitSourceLanguage is not null)
        {
            evidence = SubtitleSourceLanguageEvidence.UserPreference;
            confidence = SubtitleSourceLanguageConfidence.High;
        }
        else if (metadataLanguage is not null)
        {
            evidence = SubtitleSourceLanguageEvidence.Metadata;
            confidence = SubtitleSourceLanguageConfidence.High;
        }
        else if (titleLanguage is not null)
        {
            evidence = SubtitleSourceLanguageEvidence.TitleScript;
            confidence = SubtitleSourceLanguageConfidence.Low;
        }
        else
        {
            evidence = SubtitleSourceLanguageEvidence.Unavailable;
            confidence = SubtitleSourceLanguageConfidence.Unknown;
        }

        var targetLanguage = NormalizedLanguage(targetLanguageCode);
        var selection = SelectTrack(
            choices,
            sourceLanguageCode,
            evidence,
            targetLanguage,
            sourcePolicy,
            localAsrAvailable,
            cloudAsrAvailable);
        var reports = CandidateReports(
            choices,
            selection.Track,
            selection.Reason,
            sourceLanguageCode,
            targetLanguage,
            localAsrAvailable,
            cloudAsrAvailable);
        return new SubtitleSourceDecisionReport(
            selection.Track,
            reports,
            selection.AsrTrigger,
            selection.Reason,
            selection.Reason,
            sourceLanguageCode,
            evidence,
            confidence);
    }

    private static Selection SelectTrack(
        IReadOnlyList<SubtitleChoice> choices,
        string? sourceLanguageCode,
        SubtitleSourceLanguageEvidence evidence,
        string? targetLanguageCode,
        SubtitleSourcePolicy sourcePolicy,
        bool localAsrAvailable,
        bool cloudAsrAvailable)
    {
        switch (sourcePolicy)
        {
            case SubtitleSourcePolicy.ImportedFile:
                if (FirstTrack(choices, sourceLanguageCode, targetLanguageCode, [SubtitleSourceKind.ImportedFile]) is { } imported)
                    return new Selection(imported, SubtitleSourceDecisionReason.ImportedSubtitleExplicit, SubtitleAsrTrigger.Never);
                break;
            case SubtitleSourcePolicy.ForceLocalAsr:
                if (FirstLocalAsr(choices, sourceLanguageCode) is { } local)
                    return new Selection(local, SubtitleSourceDecisionReason.LocalRecognitionForced, SubtitleAsrTrigger.ExplicitForce);
                break;
            case SubtitleSourcePolicy.CloudAsr:
                if (cloudAsrAvailable && FirstTrack(choices, sourceLanguageCode, targetLanguageCode, [SubtitleSourceKind.CloudAsr]) is { } cloud)
                    return new Selection(cloud, SubtitleSourceDecisionReason.CloudRecognitionForced, SubtitleAsrTrigger.ExplicitForce);
                return new Selection(null, SubtitleSourceDecisionReason.CloudRecognitionUnavailable, SubtitleAsrTrigger.Never);
            case SubtitleSourcePolicy.ForcePlatform:
                if (FirstPlatformTrack(choices, sourceLanguageCode, targetLanguageCode, allowAnyLanguageFallback: true) is { } forcedPlatform)
                    return new Selection(forcedPlatform, ReasonForPlatformSelection(forcedPlatform, evidence), SubtitleAsrTrigger.Never);
                break;
            case SubtitleSourcePolicy.PreferLocalAsr:
                if (localAsrAvailable && FirstLocalAsr(choices, sourceLanguageCode) is { } preferredLocal)
                    return new Selection(preferredLocal, SubtitleSourceDecisionReason.LocalRecognitionForced, SubtitleAsrTrigger.ExplicitForce);
                break;
            case SubtitleSourcePolicy.CompareLocalAsr:
                if (FirstAutoTrack(choices, sourceLanguageCode, targetLanguageCode, allowAnyLanguageFallback: true) is { } auto)
                    return new Selection(auto, SubtitleSourceDecisionReason.CompareRequested, SubtitleAsrTrigger.ExplicitCompare);
                if (FirstLocalAsr(choices, sourceLanguageCode) is { } compareLocal)
                    return new Selection(compareLocal, SubtitleSourceDecisionReason.CompareRequested, SubtitleAsrTrigger.ExplicitForce);
                break;
        }

        if (sourcePolicy == SubtitleSourcePolicy.PreferPlatform
            && FirstPlatformTrack(choices, sourceLanguageCode, targetLanguageCode, allowAnyLanguageFallback: true) is { } platform)
        {
            return new Selection(
                platform,
                ReasonForPlatformSelection(platform, evidence),
                platform.SourceKind == SubtitleSourceKind.PlatformAuto ? SubtitleAsrTrigger.FallbackOnly : SubtitleAsrTrigger.Never);
        }

        if (FirstTrack(choices, sourceLanguageCode, targetLanguageCode, [SubtitleSourceKind.Manual]) is { } manual)
            return new Selection(manual, ReasonForManualSelection(evidence), SubtitleAsrTrigger.Never);
        if (FirstTrack(choices, sourceLanguageCode, targetLanguageCode, [SubtitleSourceKind.HlsManifest]) is { } official)
            return new Selection(official, ReasonForPlatformSelection(official, evidence), SubtitleAsrTrigger.Never);
        if (FirstAutoTrack(choices, sourceLanguageCode, targetLanguageCode, allowAnyLanguageFallback: sourceLanguageCode is null) is { } platformAuto)
            return new Selection(platformAuto, ReasonForPlatformSelection(platformAuto, evidence), SubtitleAsrTrigger.FallbackOnly);
        if (localAsrAvailable && FirstLocalAsr(choices, sourceLanguageCode) is { } fallbackLocal)
            return new Selection(fallbackLocal, SubtitleSourceDecisionReason.NoTrustedPlatformSubtitle, SubtitleAsrTrigger.FallbackOnly);
        return new Selection(null, SubtitleSourceDecisionReason.NoUsableSubtitleSource, SubtitleAsrTrigger.Never);
    }

    private static SubtitleChoice? FirstPlatformTrack(
        IReadOnlyList<SubtitleChoice> choices,
        string? sourceLanguageCode,
        string? targetLanguageCode,
        bool allowAnyLanguageFallback) =>
        FirstTrack(
            choices,
            sourceLanguageCode,
            targetLanguageCode,
            [SubtitleSourceKind.Manual, SubtitleSourceKind.HlsManifest, SubtitleSourceKind.PlatformAuto],
            allowAnyLanguageFallback);

    private static SubtitleChoice? FirstAutoTrack(
        IReadOnlyList<SubtitleChoice> choices,
        string? sourceLanguageCode,
        string? targetLanguageCode,
        bool allowAnyLanguageFallback)
    {
        var exact = choices.Select((track, index) => (track, index))
            .Where(pair => pair.track.SourceKind == SubtitleSourceKind.PlatformAuto
                && !IsTargetLanguageOnly(pair.track, sourceLanguageCode, targetLanguageCode)
                && (sourceLanguageCode is null || LanguageMatches(pair.track, sourceLanguageCode)))
            .OrderBy(pair => IsOriginalAutoVariant(pair.track) ? 0 : 1)
            .ThenBy(pair => pair.index)
            .Select(pair => pair.track)
            .FirstOrDefault();
        if (exact is not null || !allowAnyLanguageFallback) return exact;
        return choices.Select((track, index) => (track, index))
            .Where(pair => pair.track.SourceKind == SubtitleSourceKind.PlatformAuto
                && !IsTargetLanguageOnly(pair.track, sourceLanguageCode, targetLanguageCode))
            .OrderBy(pair => IsOriginalAutoVariant(pair.track) ? 0 : 1)
            .ThenBy(pair => pair.index)
            .Select(pair => pair.track)
            .FirstOrDefault();
    }

    private static SubtitleChoice? FirstTrack(
        IReadOnlyList<SubtitleChoice> choices,
        string? sourceLanguageCode,
        string? targetLanguageCode,
        SubtitleSourceKind[] kinds,
        bool allowAnyLanguageFallback = false)
    {
        var exact = choices.FirstOrDefault(track =>
            kinds.Contains(track.SourceKind)
            && !IsTargetLanguageOnly(track, sourceLanguageCode, targetLanguageCode)
            && (sourceLanguageCode is null || LanguageMatches(track, sourceLanguageCode)));
        if (exact is not null || !allowAnyLanguageFallback) return exact;
        return choices.FirstOrDefault(track =>
            kinds.Contains(track.SourceKind)
            && !IsTargetLanguageOnly(track, sourceLanguageCode, targetLanguageCode));
    }

    private static SubtitleChoice? FirstLocalAsr(IReadOnlyList<SubtitleChoice> choices, string? sourceLanguageCode)
    {
        if (sourceLanguageCode is not null
            && choices.FirstOrDefault(track =>
                track.SourceKind == SubtitleSourceKind.LocalAsr
                && NormalizedLanguage(track.LanguageCode) == sourceLanguageCode) is { } exact)
        {
            return exact;
        }
        return choices.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.LocalAsr);
    }

    private static IReadOnlyList<SubtitleSourceDecisionCandidateReport> CandidateReports(
        IReadOnlyList<SubtitleChoice> choices,
        SubtitleChoice? selected,
        SubtitleSourceDecisionReason selectedReason,
        string? sourceLanguageCode,
        string? targetLanguageCode,
        bool localAsrAvailable,
        bool cloudAsrAvailable) =>
        choices.Select(track =>
        {
            SubtitleSourceDecisionCandidateStatus status;
            SubtitleSourceDecisionReason reason;
            if (track.Id == selected?.Id)
            {
                status = SubtitleSourceDecisionCandidateStatus.Selected;
                reason = selectedReason;
            }
            else if (track.SourceKind == SubtitleSourceKind.LocalAsr)
            {
                status = localAsrAvailable ? SubtitleSourceDecisionCandidateStatus.Backup : SubtitleSourceDecisionCandidateStatus.Unavailable;
                reason = SubtitleSourceDecisionReason.LocalRecognitionFallbackOnly;
            }
            else if (track.SourceKind == SubtitleSourceKind.CloudAsr)
            {
                status = cloudAsrAvailable ? SubtitleSourceDecisionCandidateStatus.Backup : SubtitleSourceDecisionCandidateStatus.Unavailable;
                reason = cloudAsrAvailable ? SubtitleSourceDecisionReason.CloudRecognitionForced : SubtitleSourceDecisionReason.CloudRecognitionUnavailable;
            }
            else if (IsTargetLanguageOnly(track, sourceLanguageCode, targetLanguageCode))
            {
                status = SubtitleSourceDecisionCandidateStatus.NotUsed;
                reason = SubtitleSourceDecisionReason.TargetLanguageSubtitleNotSource;
            }
            else if (IsPlatformKind(track.SourceKind)
                && sourceLanguageCode is not null
                && LanguageMatches(track, sourceLanguageCode))
            {
                status = SubtitleSourceDecisionCandidateStatus.Backup;
                reason = track.SourceKind == SubtitleSourceKind.Manual
                    ? SubtitleSourceDecisionReason.ManualMatchesVideoLanguage
                    : SubtitleSourceDecisionReason.PlatformAutoMatchesVideoLanguage;
            }
            else if (track.SourceKind == SubtitleSourceKind.Manual)
            {
                status = SubtitleSourceDecisionCandidateStatus.NotUsed;
                reason = SubtitleSourceDecisionReason.ManualLanguageMismatch;
            }
            else
            {
                status = SubtitleSourceDecisionCandidateStatus.NotUsed;
                reason = SubtitleSourceDecisionReason.PlatformLanguageMismatch;
            }
            return new SubtitleSourceDecisionCandidateReport(
                track.Id,
                track.SourceKind,
                track.LanguageCode,
                track.Label,
                status,
                reason);
        }).ToList();

    private static SubtitleSourceDecisionReason ReasonForManualSelection(SubtitleSourceLanguageEvidence evidence) =>
        evidence switch
        {
            SubtitleSourceLanguageEvidence.UserPreference => SubtitleSourceDecisionReason.ManualMatchesUserLanguage,
            SubtitleSourceLanguageEvidence.Metadata => SubtitleSourceDecisionReason.ManualMatchesVideoLanguage,
            SubtitleSourceLanguageEvidence.TitleScript => SubtitleSourceDecisionReason.ManualMatchesInferredLanguage,
            _ => SubtitleSourceDecisionReason.ManualMatchesInferredLanguage,
        };

    private static SubtitleSourceDecisionReason ReasonForPlatformSelection(
        SubtitleChoice track,
        SubtitleSourceLanguageEvidence evidence)
    {
        var isAuto = track.SourceKind == SubtitleSourceKind.PlatformAuto;
        return evidence switch
        {
            SubtitleSourceLanguageEvidence.UserPreference => isAuto
                ? SubtitleSourceDecisionReason.PlatformAutoMatchesUserLanguage
                : SubtitleSourceDecisionReason.PlatformSubtitleMatchesUserLanguage,
            SubtitleSourceLanguageEvidence.Metadata => isAuto
                ? SubtitleSourceDecisionReason.PlatformAutoMatchesVideoLanguage
                : SubtitleSourceDecisionReason.PlatformSubtitleMatchesVideoLanguage,
            _ => isAuto
                ? SubtitleSourceDecisionReason.PlatformAutoMatchesInferredLanguage
                : SubtitleSourceDecisionReason.PlatformSubtitleMatchesInferredLanguage,
        };
    }

    private static bool IsPlatformKind(SubtitleSourceKind kind) =>
        kind is SubtitleSourceKind.Manual or SubtitleSourceKind.PlatformAuto or SubtitleSourceKind.HlsManifest;

    private static bool IsTargetLanguageOnly(
        SubtitleChoice track,
        string? sourceLanguageCode,
        string? targetLanguageCode) =>
        targetLanguageCode is not null
        && NormalizedLanguage(track.LanguageCode) == targetLanguageCode
        && sourceLanguageCode != targetLanguageCode;

    private static bool LanguageMatches(SubtitleChoice track, string? sourceLanguageCode) =>
        sourceLanguageCode is not null && NormalizedLanguage(track.LanguageCode) == sourceLanguageCode;

    private static string? NormalizedExplicitSourceLanguage(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed) || string.Equals(trimmed, "auto", StringComparison.OrdinalIgnoreCase)) return null;
        return NormalizedLanguage(trimmed);
    }

    private static string? NormalizedLanguage(string? value)
    {
        var normalized = LanguageCatalog.Normalize(value);
        return normalized.Length == 0 ? null : normalized;
    }

    private static bool IsOriginalAutoVariant(SubtitleChoice track)
    {
        var code = track.LanguageCode.ToLowerInvariant();
        if (code.Contains("-orig", StringComparison.Ordinal)) return true;
        if (track.Variant?.ToLowerInvariant().Contains("orig", StringComparison.Ordinal) == true) return true;
        return track.Metadata.TryGetValue("isOrig", out var isOrig) && isOrig == "true";
    }
}
