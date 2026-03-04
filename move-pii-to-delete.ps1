param(
    [string]$SourceRoot = "C:\PROP",
    [string]$DeleteRoot = "C:\PROP\delete",
    [bool]$DryRun = $true,
    [ValidateSet("Full", "Fast", "OcrOnly")]
    [string]$ScanMode = "Full",
    [int]$ProgressEvery = 250,
    [int]$MaxFiles = 0,
    [int64]$MaxTextFileBytes = 5MB,
    [int64]$MaxOcrFileBytes = 30MB,
    [bool]$EnableOcr = $false,
    [string]$TesseractPath = "tesseract",
    [bool]$EnablePdfOcr = $false,
    [string]$PdfToPpmPath = "pdftoppm",
    [int]$MaxPdfPages = 2,
    [bool]$UseOcrCandidateFilter = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    Write-Host "Source folder not found: $SourceRoot"
    exit 1
}

if (-not (Test-Path -LiteralPath $DeleteRoot)) {
    New-Item -ItemType Directory -Path $DeleteRoot -Force | Out-Null
}

$sourceRootNormalized = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$deleteRootNormalized = [System.IO.Path]::GetFullPath($DeleteRoot).TrimEnd('\')
$deleteRootPrefix = $deleteRootNormalized + '\'
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $DeleteRoot ("pii-move-" + $timestamp + ".log")

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line
}

function Test-ContentPatterns {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Regexes
    )
    foreach ($rx in $Regexes) {
        if ($Content -match $rx) { return $true }
    }
    return $false
}

function Test-IsLikelyOcrCandidate {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $candidateHints = @(
        "scan", "scanned", "resident", "application", "app", "w2", "w-2",
        "ssn", "social", "security", "license", "driver", "id", "income", "paystub", "pay stub"
    )
    $full = $File.FullName.ToLowerInvariant()
    foreach ($hint in $candidateHints) {
        if ($full.Contains($hint)) { return $true }
    }
    return $false
}

function Get-OcrText {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$TesseractExe
    )
    $ocrOutput = & $TesseractExe $ImagePath stdout -l eng 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Tesseract failed (exit " + $LASTEXITCODE + "): " + ($ocrOutput -join " "))
    }
    return ($ocrOutput -join [Environment]::NewLine)
}

function Get-PdfOcrText {
    param(
        [Parameter(Mandatory = $true)][string]$PdfPath,
        [Parameter(Mandatory = $true)][string]$PdfToPpmExe,
        [Parameter(Mandatory = $true)][string]$TesseractExe,
        [Parameter(Mandatory = $true)][int]$PageLimit,
        [Parameter(Mandatory = $true)][string]$TempDir
    )
    $pageCount = 0
    $allText = ""
    $prefix = Join-Path $TempDir ("pdfocr-" + [System.Guid]::NewGuid().ToString("N"))
    try {
        $renderOutput = & $PdfToPpmExe @("-png", "-f", "1", "-l", $PageLimit.ToString(), $PdfPath, $prefix) 2>&1
        $images = @(Get-ChildItem -Path ($prefix + "-*.png") -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if (($LASTEXITCODE -ne 0) -and ($images.Count -eq 0)) {
            throw ("pdftoppm failed (exit " + $LASTEXITCODE + "): " + ($renderOutput -join " "))
        }
        foreach ($img in $images) {
            $pageCount++
            $allText += (Get-OcrText -ImagePath $img.FullName -TesseractExe $TesseractExe)
            $allText += [Environment]::NewLine
        }
    } finally {
        Remove-Item -Path ($prefix + "-*.png") -Force -ErrorAction SilentlyContinue
    }
    return @{ Text = $allText; PagesProcessed = $pageCount }
}

$fileNameRegex = '(?i)(\bssn\b|social[\s._-]*security|driver[\s._-]*licen[sc]e|dl[\s._-]*copy|w[\s._-]*2\b|pay[\s._-]*stub|paystub|pay[\s._-]*statement)'
$contentRegexes = @(
    '(?i)\bsocial\s+security\b',
    '(?i)\bssn\b',
    '(?i)\bdriver[''s]{0,2}\s+licen[sc]e\b',
    '(?i)\bw[\s-]*2\b',
    '(?i)\bpay\s*stub\b',
    '\b\d{3}-\d{2}-\d{4}\b'
)
$contentExtensions = @(".txt", ".csv", ".log", ".md", ".json", ".xml", ".html", ".htm", ".rtf")
$ocrExtensions = @(".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif")
$pdfExtensions = @(".pdf")

$scanByName = ($ScanMode -ne "OcrOnly")
$scanText = ($ScanMode -ne "OcrOnly")
$scanOcr = ($ScanMode -ne "Fast")

$scanned = 0
$matched = 0
$moved = 0
$skippedInDeleteFolder = 0
$skippedByMode = 0
$skippedBySize = 0
$skippedByCandidateFilter = 0
$readErrors = 0
$moveErrors = 0
$ocrScanned = 0
$ocrErrors = 0
$pdfScanned = 0
$pdfPagesProcessed = 0
$pdfErrors = 0
$readErrorDetails = New-Object System.Collections.Generic.List[string]
$moveErrorDetails = New-Object System.Collections.Generic.List[string]
$ocrErrorDetails = New-Object System.Collections.Generic.List[string]
$pdfErrorDetails = New-Object System.Collections.Generic.List[string]

$ocrEnabledForRun = ($EnableOcr -and $scanOcr)
$pdfOcrEnabledForRun = ($EnablePdfOcr -and $scanOcr)

if ($scanOcr -and (-not $EnableOcr) -and (-not $EnablePdfOcr) -and ($ScanMode -ne "Fast")) {
    Write-Log "[INFO] ScanMode enables OCR path, but OCR flags are off; only name/text scanning will run."
}

if ($ocrEnabledForRun -or $pdfOcrEnabledForRun) {
    $tesseractCommand = Get-Command $TesseractPath -ErrorAction SilentlyContinue
    if ($null -eq $tesseractCommand) {
        Write-Log ("[OCR DISABLED] Tesseract not found: " + $TesseractPath)
        $ocrEnabledForRun = $false
        $pdfOcrEnabledForRun = $false
    } else {
        $TesseractPath = $tesseractCommand.Source
        Write-Log ("[OCR ENABLED] Using Tesseract: " + $TesseractPath)
    }
}

if ($pdfOcrEnabledForRun) {
    if ($MaxPdfPages -lt 1) {
        Write-Log "[PDF OCR DISABLED] MaxPdfPages must be >= 1."
        $pdfOcrEnabledForRun = $false
    } else {
        $pdfToPpmCommand = Get-Command $PdfToPpmPath -ErrorAction SilentlyContinue
        if ($null -eq $pdfToPpmCommand) {
            Write-Log ("[PDF OCR DISABLED] pdftoppm not found: " + $PdfToPpmPath)
            $pdfOcrEnabledForRun = $false
        } else {
            $PdfToPpmPath = $pdfToPpmCommand.Source
            Write-Log ("[PDF OCR ENABLED] Using pdftoppm: " + $PdfToPpmPath + "; MaxPdfPages=" + $MaxPdfPages)
        }
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log ("Starting PII scan. SourceRoot=" + $sourceRootNormalized + "; DeleteRoot=" + $deleteRootNormalized + "; DryRun=" + $DryRun + "; ScanMode=" + $ScanMode + "; UseOcrCandidateFilter=" + $UseOcrCandidateFilter + "; MaxFiles=" + $MaxFiles)

$fileStream = Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -ErrorAction SilentlyContinue
if ($MaxFiles -gt 0) {
    $fileStream = $fileStream | Select-Object -First $MaxFiles
}

$fileStream | ForEach-Object {
    $file = $_
    $scanned++

    if ($file.FullName.Equals($deleteRootNormalized, [System.StringComparison]::OrdinalIgnoreCase) -or
        $file.FullName.StartsWith($deleteRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $skippedInDeleteFolder++
        return
    }

    $isMatch = $false
    $matchReason = ""
    $extension = $file.Extension.ToLowerInvariant()

    if ($scanByName -and ($file.Name -match $fileNameRegex)) {
        $isMatch = $true
        $matchReason = "filename"
    }

    if ((-not $isMatch) -and $scanText -and ($contentExtensions -contains $extension)) {
        if (($MaxTextFileBytes -gt 0) -and ($file.Length -gt $MaxTextFileBytes)) {
            $skippedBySize++
        } else {
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                if (Test-ContentPatterns -Content $content -Regexes $contentRegexes) {
                    $isMatch = $true
                    $matchReason = "content"
                }
            } catch {
                $readErrors++
                $errorMessage = $_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = "Unknown read error" }
                $detail = ($file.FullName + " | " + $errorMessage)
                $readErrorDetails.Add($detail)
                Write-Log ("[READ ERROR] " + $detail)
            }
        }
    }

    if ((-not $isMatch) -and $scanOcr) {
        $candidateAllowed = (-not $UseOcrCandidateFilter) -or (Test-IsLikelyOcrCandidate -File $file)
        if (-not $candidateAllowed) {
            if (($ocrExtensions -contains $extension) -or ($pdfExtensions -contains $extension)) {
                $skippedByCandidateFilter++
            }
        } elseif (($MaxOcrFileBytes -gt 0) -and ($file.Length -gt $MaxOcrFileBytes)) {
            if (($ocrExtensions -contains $extension) -or ($pdfExtensions -contains $extension)) {
                $skippedBySize++
            }
        } elseif ($ocrEnabledForRun -and ($ocrExtensions -contains $extension)) {
            try {
                $ocrScanned++
                $ocrText = Get-OcrText -ImagePath $file.FullName -TesseractExe $TesseractPath
                if (Test-ContentPatterns -Content $ocrText -Regexes $contentRegexes) {
                    $isMatch = $true
                    $matchReason = "ocr"
                }
            } catch {
                $ocrErrors++
                $ocrErrorMessage = $_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($ocrErrorMessage)) { $ocrErrorMessage = "Unknown OCR error" }
                $ocrDetail = ($file.FullName + " | " + $ocrErrorMessage)
                $ocrErrorDetails.Add($ocrDetail)
                Write-Log ("[OCR ERROR] " + $ocrDetail)
            }
        } elseif ($pdfOcrEnabledForRun -and ($pdfExtensions -contains $extension)) {
            try {
                $pdfScanned++
                $pdfResult = Get-PdfOcrText -PdfPath $file.FullName -PdfToPpmExe $PdfToPpmPath -TesseractExe $TesseractPath -PageLimit $MaxPdfPages -TempDir $DeleteRoot
                $pdfPagesProcessed += [int]$pdfResult.PagesProcessed
                $pdfText = [string]$pdfResult.Text
                if (Test-ContentPatterns -Content $pdfText -Regexes $contentRegexes) {
                    $isMatch = $true
                    $matchReason = "pdf-ocr"
                }
            } catch {
                $pdfErrors++
                $pdfErrorMessage = $_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($pdfErrorMessage)) { $pdfErrorMessage = "Unknown PDF OCR error" }
                $pdfDetail = ($file.FullName + " | " + $pdfErrorMessage)
                $pdfErrorDetails.Add($pdfDetail)
                Write-Log ("[PDF OCR ERROR] " + $pdfDetail)
            }
        } else {
            $skippedByMode++
        }
    }

    if ($isMatch) {
        $matched++
        $relativePath = $file.FullName.Substring($sourceRootNormalized.Length).TrimStart('\')
        $destinationPath = Join-Path $DeleteRoot $relativePath
        $destinationDir = Split-Path -Path $destinationPath -Parent
        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }
        if ($DryRun) {
            Write-Log ("[DRY RUN][" + $matchReason + "] " + $file.FullName + " -> " + $destinationPath)
        } else {
            try {
                Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force -ErrorAction Stop
                $moved++
                Write-Log ("[MOVED][" + $matchReason + "] " + $file.FullName + " -> " + $destinationPath)
            } catch {
                $moveErrors++
                $moveErrorMessage = $_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($moveErrorMessage)) { $moveErrorMessage = "Unknown move error" }
                $moveDetail = ($file.FullName + " -> " + $destinationPath + " | " + $moveErrorMessage)
                $moveErrorDetails.Add($moveDetail)
                Write-Log ("[MOVE ERROR] " + $moveDetail)
            }
        }
    }

    if (($ProgressEvery -gt 0) -and (($scanned % $ProgressEvery) -eq 0)) {
        Write-Log ("Progress: scanned=" + $scanned + "; matched=" + $matched + "; moved=" + $moved + "; ocrScanned=" + $ocrScanned + "; pdfScanned=" + $pdfScanned + "; pdfPagesProcessed=" + $pdfPagesProcessed + "; skippedByCandidate=" + $skippedByCandidateFilter + "; skippedBySize=" + $skippedBySize + "; readErrors=" + $readErrors + "; ocrErrors=" + $ocrErrors + "; pdfErrors=" + $pdfErrors + "; moveErrors=" + $moveErrors)
    }
}

$stopwatch.Stop()
Write-Log ("Complete: scanned=" + $scanned + "; matched=" + $matched + "; moved=" + $moved + "; skippedInDelete=" + $skippedInDeleteFolder + "; skippedByMode=" + $skippedByMode + "; skippedByCandidate=" + $skippedByCandidateFilter + "; skippedBySize=" + $skippedBySize + "; ocrScanned=" + $ocrScanned + "; pdfScanned=" + $pdfScanned + "; pdfPagesProcessed=" + $pdfPagesProcessed + "; readErrors=" + $readErrors + "; ocrErrors=" + $ocrErrors + "; pdfErrors=" + $pdfErrors + "; moveErrors=" + $moveErrors + "; elapsed=" + [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2) + "s")

if ($readErrorDetails.Count -gt 0) {
    Write-Log "Read error files:"
    foreach ($readError in $readErrorDetails) { Write-Log ("  - " + $readError) }
}
if ($ocrErrorDetails.Count -gt 0) {
    Write-Log "OCR error files:"
    foreach ($ocrError in $ocrErrorDetails) { Write-Log ("  - " + $ocrError) }
}
if ($pdfErrorDetails.Count -gt 0) {
    Write-Log "PDF OCR error files:"
    foreach ($pdfError in $pdfErrorDetails) { Write-Log ("  - " + $pdfError) }
}
if ($moveErrorDetails.Count -gt 0) {
    Write-Log "Move error files:"
    foreach ($moveError in $moveErrorDetails) { Write-Log ("  - " + $moveError) }
}
if ($DryRun) {
    Write-Log "Dry run complete. Re-run with -DryRun:`$false to move files."
}
Write-Host ("Log file: " + $logPath)
