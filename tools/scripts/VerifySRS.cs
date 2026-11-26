using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace SrsIntegrity.Engine
{
    /// <summary>
    /// 高信頼性エンタープライズ要件定義書（SRS）テキスト整合性およびヒューマンエラー遮断リンター
    /// (High-Reliability Enterprise SRS Text Integrity & Human-Error Blocker)
    /// </summary>
    public class SrsIntegrityVerifier
    {
        public class Finding
        {
            public string RuleId { get; set; }
            public string Severity { get; set; } // FATAL, WARN, INFO
            public int LineNumber { get; set; }
            public int ColumnNumber { get; set; }
            public string Message { get; set; }
            public string ContextSnippet { get; set; }
        }

        public class VerificationResult
        {
            public int ExitCode { get; set; }
            public int FatalCount { get; set; }
            public int WarningCount { get; set; }
            public List<Finding> Findings { get; set; }

            public VerificationResult()
            {
                Findings = new List<Finding>();
            }
        }

        public static int Main(string[] args)
        {
            try
            {
                if (args.Length == 0)
                {
                    Console.WriteLine("Usage: VerifySRS_Integrity.exe <TargetFilePath> [PolicyRulesPath]");
                    return 3;
                }

                string targetFile = args[0];
                string policyFile = args.Length > 1 ? args[1] : null;

                VerificationResult result = Verify(targetFile, policyFile);
                return result.ExitCode;
            }
            catch (Exception ex)
            {
                Console.WriteLine(string.Format("[FATAL UNHANDLED EXCEPTION] {0}", ex.Message));
                return 3;
            }
        }

        public static VerificationResult Verify(string filePath, string policyPath = null)
        {
            VerificationResult result = new VerificationResult();

            if (!File.Exists(filePath))
            {
                Console.WriteLine(string.Format("[EXECUTION ERROR] Target file not found: {0}", filePath));
                result.ExitCode = 3;
                return result;
            }

            byte[] rawBytes;
            try
            {
                rawBytes = File.ReadAllBytes(filePath);
            }
            catch (Exception ex)
            {
                Console.WriteLine(string.Format("[EXECUTION ERROR] Failed to read bytes: {0}", ex.Message));
                result.ExitCode = 3;
                return result;
            }

            // =========================================================================
            // PHASE 1: Byte-Level & Encoding Integrity (Fail-Closed)
            // =========================================================================
            
            // 1-1. BOM Check (Rule: TEXT-001)
            if (rawBytes.Length >= 3 && rawBytes[0] == 0xEF && rawBytes[1] == 0xBB && rawBytes[2] == 0xBF)
            {
                result.Findings.Add(new Finding
                {
                    RuleId = "TEXT-001",
                    Severity = "WARN",
                    LineNumber = 1,
                    ColumnNumber = 1,
                    Message = "UTF-8 BOM detected. Enterprise git repos standardly require UTF-8 without BOM.",
                    ContextSnippet = "BOM [EF BB BF]"
                });
            }

            // 1-2. Split into raw lines using LF/CRLF while preserving line indices
            List<byte[]> rawLines = SplitBytesIntoLines(rawBytes);

            for (int i = 0; i < rawLines.Count; i++)
            {
                int lineNum = i + 1;
                byte[] lBytes = rawLines[i];

                // Carriage Return check (TEXT-005)
                for (int b = 0; b < lBytes.Length; b++)
                {
                    if (lBytes[b] == 0x0D)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "TEXT-005",
                            Severity = "WARN",
                            LineNumber = lineNum,
                            ColumnNumber = b + 1,
                            Message = "Carriage Return (CR, 0x0D) detected. Unified LF line-ending is recommended.",
                            ContextSnippet = "\\r detected"
                        });
                        break;
                    }
                }

                // Invisible Characters (Zero-Width Space, Soft Hyphen, etc.)
                // U+200B (Zero-width space: E2 80 8B)
                // U+FEFF in-body (Zero-width no-break space: EF BB BF)
                // U+00AD (Soft hyphen: C2 AD)
                for (int b = 0; b < lBytes.Length; b++)
                {
                    if (b + 2 < lBytes.Length && lBytes[b] == 0xE2 && lBytes[b + 1] == 0x80 && lBytes[b + 2] == 0x8B)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "TEXT-002",
                            Severity = "FATAL",
                            LineNumber = lineNum,
                            ColumnNumber = b + 1,
                            Message = "Zero-Width Space (U+200B) detected. Hidden non-printable characters violate strict spec integrity.",
                            ContextSnippet = "[E2 80 8B]"
                        });
                    }
                    if (b + 2 < lBytes.Length && lBytes[b] == 0xEF && lBytes[b + 1] == 0xBB && lBytes[b + 2] == 0xBF && lineNum > 1)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "TEXT-001",
                            Severity = "FATAL",
                            LineNumber = lineNum,
                            ColumnNumber = b + 1,
                            Message = "U+FEFF (Zero-Width No-Break Space) detected within body.",
                            ContextSnippet = "[EF BB BF]"
                        });
                    }
                    if (b + 1 < lBytes.Length && lBytes[b] == 0xC2 && lBytes[b + 1] == 0xAD)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "TEXT-003",
                            Severity = "FATAL",
                            LineNumber = lineNum,
                            ColumnNumber = b + 1,
                            Message = "Soft Hyphen (U+00AD) detected. Invisible hyphenation breaks automated parser contracts.",
                            ContextSnippet = "[C2 AD]"
                        });
                    }
                    // U+FFFD (Replacement character: EF BF BD) - Corrupted UTF-8
                    if (b + 2 < lBytes.Length && lBytes[b] == 0xEF && lBytes[b + 1] == 0xBF && lBytes[b + 2] == 0xBD)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "TEXT-004",
                            Severity = "FATAL",
                            LineNumber = lineNum,
                            ColumnNumber = b + 1,
                            Message = "Corrupted UTF-8 Replacement Character (U+FFFD) detected.",
                            ContextSnippet = "[EF BF BD]"
                        });
                    }
                }
            }

            // =========================================================================
            // PHASE 2: Spec Syntax & Quality Rules (Line-by-Line)
            // =========================================================================
            // Strict UTF-8 decoder that throws DecoderFallbackException on any invalid byte sequence
            UTF8Encoding strictUtf8 = new UTF8Encoding(false, true);
            string fullText;
            try
            {
                fullText = strictUtf8.GetString(rawBytes);
            }
            catch (DecoderFallbackException ex)
            {
                Console.WriteLine(string.Format("[FATAL] [TEXT-004] Invalid non-UTF-8 byte sequence detected: {0}", ex.Message));
                result.Findings.Add(new Finding
                {
                    RuleId = "TEXT-004",
                    Severity = "FATAL",
                    LineNumber = 1,
                    ColumnNumber = 1,
                    Message = "Invalid non-UTF-8 byte sequence detected (Encoding integrity violated).",
                    ContextSnippet = ex.Message
                });
                result.ExitCode = 2;
                return result;
            }
            catch (Exception ex)
            {
                Console.WriteLine(string.Format("[EXECUTION ERROR] UTF-8 decoding failed: {0}", ex.Message));
                result.ExitCode = 3;
                return result;
            }

            string[] lines = fullText.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);

            // 2-0. CSV Column Cardinality, Monotonicity & Cross-Ledger Gate (Rule: CSV-001, CSV-002, CSV-004)
            // RFC 4180 State Machine Parser: Preserves quoted commas and handles escaped quotes
            if (filePath.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
            {
                int expectedCols = -1;
                DateTime? lastTimestamp = null;
                int timestampColIdx = -1;

                for (int c = 0; c < lines.Length; c++)
                {
                    string row = lines[c].Trim();
                    if (string.IsNullOrEmpty(row)) continue;
                    List<string> cols = ParseCsvRow(row);
                    if (expectedCols == -1)
                    {
                        expectedCols = cols.Count;
                        // Determine timestamp column index
                        for (int colIdx = 0; colIdx < cols.Count; colIdx++)
                        {
                            string colHeader = cols[colIdx].Trim('\"', ' ');
                            if (colHeader.Equals("Timestamp", StringComparison.OrdinalIgnoreCase) ||
                                colHeader.Equals("timestamp", StringComparison.OrdinalIgnoreCase) ||
                                colHeader.Equals("ExecutionTime", StringComparison.OrdinalIgnoreCase))
                            {
                                timestampColIdx = colIdx;
                                break;
                            }
                        }
                    }
                    else if (cols.Count != expectedCols)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "CSV-001",
                            Severity = "FATAL",
                            LineNumber = c + 1,
                            ColumnNumber = 1,
                            Message = string.Format("CSV Column Cardinality mismatch. Expected {0} columns based on header, but row has {1} columns.", expectedCols, cols.Count),
                            ContextSnippet = row.Length > 60 ? row.Substring(0, 60) + "..." : row
                        });
                    }
                    else if (timestampColIdx >= 0 && timestampColIdx < cols.Count)
                    {
                        // Check Timestamp Monotonicity (Rule: CSV-002)
                        string rawTs = cols[timestampColIdx].Trim('\"', ' ');
                        DateTime currentTs;
                        string cleanTs = rawTs.Replace(" - ", " ").Replace("/", "-");
                        if (DateTime.TryParse(cleanTs, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out currentTs))
                        {
                            if (lastTimestamp.HasValue && currentTs < lastTimestamp.Value.AddSeconds(-60))
                            {
                                result.Findings.Add(new Finding
                                {
                                    RuleId = "CSV-002",
                                    Severity = "FATAL",
                                    LineNumber = c + 1,
                                    ColumnNumber = 1,
                                    Message = string.Format("Chronological ordering violation. Timestamp '{0}' is earlier than previous row timestamp '{1}'.", rawTs, lastTimestamp.Value.ToString("yyyy-MM-dd HH:mm:ss")),
                                    ContextSnippet = row.Length > 60 ? row.Substring(0, 60) + "..." : row
                                });
                            }
                            lastTimestamp = currentTs;
                        }
                    }
                }

                // Rule CSV-004: Cross-Ledger Sibling Synchronization Hard-Gate
                string fileName = Path.GetFileName(filePath);
                string dirPath = Path.GetDirectoryName(filePath);
                if (string.IsNullOrEmpty(dirPath)) dirPath = ".";

                if (fileName.Equals("local_token_ledger.csv", StringComparison.OrdinalIgnoreCase) ||
                    fileName.Equals("cloud_api_token_ledger.csv", StringComparison.OrdinalIgnoreCase) ||
                    fileName.Equals("codex_token_ledger.csv", StringComparison.OrdinalIgnoreCase) ||
                    fileName.Equals("enterprise_audit_ledger.csv", StringComparison.OrdinalIgnoreCase))
                {
                    string enterprisePath = Path.Combine(dirPath, "enterprise_audit_ledger.csv");
                    if (File.Exists(enterprisePath) && lastTimestamp.HasValue)
                    {
                        DateTime? maxEnterpriseDate = ExtractMaxDateFromLedger(enterprisePath, 0);
                        if (maxEnterpriseDate.HasValue)
                        {
                            TimeSpan diff = maxEnterpriseDate.Value.Date - lastTimestamp.Value.Date;
                            if (diff.TotalDays >= 1)
                            {
                                result.Findings.Add(new Finding
                                {
                                    RuleId = "CSV-004",
                                    Severity = "FATAL",
                                    LineNumber = lines.Length,
                                    ColumnNumber = 1,
                                    Message = string.Format("Sibling Ledger De-synchronization. '{0}' latest entry is at '{1}', but enterprise_audit_ledger.csv has latest entry at '{2}' ({3} days gap). All audit logs must be synchronized.",
                                        fileName, lastTimestamp.Value.ToString("yyyy-MM-dd"), maxEnterpriseDate.Value.ToString("yyyy-MM-dd"), (int)diff.TotalDays),
                                    ContextSnippet = string.Format("Target: {0} vs Enterprise: {1}", lastTimestamp.Value.ToString("yyyy-MM-dd"), maxEnterpriseDate.Value.ToString("yyyy-MM-dd"))
                                });
                            }
                        }
                    }
                }
            }

            int consecutiveBlankLines = 0;
            Dictionary<string, int> headingTracker = new Dictionary<string, int>();

            for (int i = 0; i < lines.Length; i++)
            {
                int lineNum = i + 1;
                string line = lines[i];
                string trimmed = line.Trim();

                // 2-1. Excessive Consecutive Blank Lines (FORMAT-001)
                if (string.IsNullOrEmpty(trimmed))
                {
                    consecutiveBlankLines++;
                    if (consecutiveBlankLines >= 3)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "FORMAT-001",
                            Severity = "WARN",
                            LineNumber = lineNum,
                            ColumnNumber = 1,
                            Message = string.Format("Excessive blank lines detected ({0} consecutive empty lines). Clean formatting required.", consecutiveBlankLines),
                            ContextSnippet = "(Empty line)"
                        });
                    }
                }
                else
                {
                    consecutiveBlankLines = 0;
                }

                // 2-2. Unspaced Tilde Violation (SPEC-001)
                // e.g. 10~20, 22:00~05:00 -> Causes markdown strikethrough corruption
                Match unspacedTilde = Regex.Match(line, @"([^\s`])~([^\s`])");
                if (unspacedTilde.Success && !line.Contains("```"))
                {
                    result.Findings.Add(new Finding
                    {
                        RuleId = "SPEC-001",
                        Severity = "WARN",
                        LineNumber = lineNum,
                        ColumnNumber = unspacedTilde.Index + 1,
                        Message = "Unspaced tilde (~) detected. Markdown interpreters render this as strikethrough. Use ' ~ ' or backticks.",
                        ContextSnippet = GetContextSnippet(line, unspacedTilde.Index, 10)
                    });
                }

                // 2-3. Zero-Korean Hard-Gate (Rule: SEC-001)
                // Enforces zero-korean unicode on public files (excluding local _KO files)
                if (!filePath.Contains("_KO.") && !filePath.Contains("_ko."))
                {
                    Match koreanMatch = Regex.Match(line, @"[\uAC00-\uD7A3\u1100-\u11FF\u3130-\u318F\uA960-\uA97F\uD7B0-\uD7FF]");
                    if (koreanMatch.Success)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "SEC-001",
                            Severity = "FATAL",
                            LineNumber = lineNum,
                            ColumnNumber = koreanMatch.Index + 1,
                            Message = "Zero-Korean violation: Korean unicode character detected in public repository file.",
                            ContextSnippet = GetContextSnippet(line, koreanMatch.Index, 10)
                        });
                    }
                }

                // 2-4. Sensitive Infrastructure & Path Leakage (Rule: SEC-002)
                // Scans for private IPv4 CIDR blocks and local user directory patterns
                Match sensitiveMatch = Regex.Match(line, @"\b(192\.168\.\d{1,3}\.\d{1,3}|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3})\b|C:\\Users\\[a-zA-Z0-9_-]+");
                if (sensitiveMatch.Success)
                {
                    result.Findings.Add(new Finding
                    {
                        RuleId = "SEC-002",
                        Severity = "FATAL",
                        LineNumber = lineNum,
                        ColumnNumber = sensitiveMatch.Index + 1,
                        Message = "Sensitive data leakage: Private IP range or local user path detected.",
                        ContextSnippet = GetContextSnippet(line, sensitiveMatch.Index, 10)
                    });
                }

                // 2-5. Ambiguous Engineering Placeholders (SPEC-002)
                // e.g. TBD, TODO, 未定, 未確定, 追って決定
                Match placeholder = Regex.Match(line, @"\b(TBD|TODO|FIXME|WIP)\b|(未定|未確定|追って決定)");
                bool isRuleDefinitionRow = line.TrimStart().StartsWith("|") && (line.Contains("SPEC-002") || line.Contains("RULE-FMT-02"));
                if (placeholder.Success && !isRuleDefinitionRow)
                {
                    result.Findings.Add(new Finding
                    {
                        RuleId = "SPEC-002",
                        Severity = "WARN",
                        LineNumber = lineNum,
                        ColumnNumber = placeholder.Index + 1,
                        Message = string.Format("Unfinalized specification placeholder detected: '{0}'. All requirements must be concrete in approved SSOT.", placeholder.Value),
                        ContextSnippet = GetContextSnippet(line, placeholder.Index, 15)
                    });
                }

                // 2-4. Duplicate Headings Check (SPEC-003)
                if (trimmed.StartsWith("#"))
                {
                    Match headingMatch = Regex.Match(trimmed, @"^(#+)\s+(.+)$");
                    if (headingMatch.Success)
                    {
                        string headingText = headingMatch.Groups[2].Value.Trim();
                        if (headingTracker.ContainsKey(headingText))
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "SPEC-003",
                                Severity = "WARN",
                                LineNumber = lineNum,
                                ColumnNumber = 1,
                                Message = string.Format("Duplicate heading detected: '{0}' (First seen at line {1}). Causes anchor conflicts.", headingText, headingTracker[headingText]),
                                ContextSnippet = trimmed
                            });
                        }
                        else
                        {
                            headingTracker[headingText] = lineNum;
                        }
                    }
                }
            }

            // =========================================================================
            // PHASE 3: Large Block Duplicate Detection (Anti-Copy-Paste Integrity)
            // =========================================================================
            Dictionary<string, int> paragraphSeen = new Dictionary<string, int>();
            StringBuilder currentBlock = new StringBuilder();
            int blockStartLine = 1;

            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i];
                if (string.IsNullOrWhiteSpace(line))
                {
                    if (currentBlock.Length > 0)
                    {
                        CheckBlockDuplicate(currentBlock.ToString(), blockStartLine, paragraphSeen, result);
                        currentBlock.Clear();
                    }
                    blockStartLine = i + 2;
                }
                else
                {
                    currentBlock.AppendLine(line);
                }
            }
            if (currentBlock.Length > 0)
            {
                CheckBlockDuplicate(currentBlock.ToString(), blockStartLine, paragraphSeen, result);
            }

            // =========================================================================
            // PHASE 4: External Finding Queue Fail-Closed Gate (GEMINI.md Rule 9)
            // =========================================================================
            string fullTarget = Path.GetFullPath(filePath);
            string projectRoot = null;
            string probeDir = Path.GetDirectoryName(fullTarget);
            while (!string.IsNullOrEmpty(probeDir))
            {
                if (Directory.Exists(Path.Combine(probeDir, ".git")) ||
                    File.Exists(Path.Combine(probeDir, "GEMINI.md")))
                {
                    projectRoot = probeDir;
                    break;
                }
                DirectoryInfo parent = Directory.GetParent(probeDir);
                if (parent == null) break;
                probeDir = parent.FullName;
            }
            if (string.IsNullOrEmpty(projectRoot))
            {
                projectRoot = Directory.GetCurrentDirectory();
            }

            string pendingQueuePath = Path.Combine(projectRoot, "scratch", "pending_findings.json");
            if (File.Exists(pendingQueuePath))
            {
                try
                {
                    string queueJson = File.ReadAllText(pendingQueuePath, Encoding.UTF8);
                    int actualCount = 0;
                    Match countMatch = Regex.Match(queueJson, @"""declared_count""\s*:\s*(-?\d+)");
                    if (!countMatch.Success)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "PROC-001",
                            Severity = "FATAL",
                            LineNumber = 1,
                            ColumnNumber = 1,
                            Message = "Malformed finding queue: 'declared_count' field is missing. Fail-Closed required.",
                            ContextSnippet = pendingQueuePath
                        });
                    }
                    else
                    {
                        int declaredCount = int.Parse(countMatch.Groups[1].Value);
                        MatchCollection findingMatches = Regex.Matches(queueJson, @"""id""\s*:\s*""([^""]+)""");
                        actualCount = findingMatches.Count;

                        if (declaredCount != actualCount || declaredCount < 0)
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "PROC-001",
                                Severity = "FATAL",
                                LineNumber = 1,
                                ColumnNumber = 1,
                                Message = string.Format("Finding queue count mismatch: declared_count={0} but actual findings={1}.", declaredCount, actualCount),
                                ContextSnippet = pendingQueuePath
                            });
                        }
                    }

                    MatchCollection statusMatches = Regex.Matches(queueJson, @"""status""\s*:\s*""([^""]+)""");
                    if (statusMatches.Count != actualCount)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "PROC-002",
                            Severity = "FATAL",
                            LineNumber = 1,
                            ColumnNumber = 1,
                            Message = string.Format("Finding queue status field count mismatch: actual findings={0} but status count={1}. All items must have an explicit status.", actualCount, statusMatches.Count),
                            ContextSnippet = pendingQueuePath
                        });
                    }
                    foreach (Match sm in statusMatches)
                    {
                        string st = sm.Groups[1].Value.Trim();
                        if (!st.Equals("RESOLVED", StringComparison.OrdinalIgnoreCase))
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "PROC-002",
                                Severity = "FATAL",
                                LineNumber = 1,
                                ColumnNumber = 1,
                                Message = string.Format("Unresolved finding status '{0}' in scratch/pending_findings.json. All items must reach RESOLVED before commit.", st),
                                ContextSnippet = pendingQueuePath
                            });
                            break;
                        }
                    }
                }
                catch (Exception ex)
                {
                    result.Findings.Add(new Finding
                    {
                        RuleId = "PROC-003",
                        Severity = "FATAL",
                        LineNumber = 1,
                        ColumnNumber = 1,
                        Message = "Failed to parse scratch/pending_findings.json: " + ex.Message,
                        ContextSnippet = pendingQueuePath
                    });
                }
            }

            string targetFileName = Path.GetFileName(filePath).ToLowerInvariant();
            string targetNormPath = filePath.Replace("/", "\\").ToLowerInvariant();
            bool isSsotFile = targetFileName.Equals("srs_specification_ssot.md", StringComparison.OrdinalIgnoreCase);

            if (isSsotFile)
            {

                    // =========================================================================
                    // PHASE 5: Code-to-Spec Bidirectional Traceability Gate (SPEC-004)
                    // =========================================================================
                    string mirrorDir = Path.Combine(projectRoot, @"domain_target\03_core_domain_services");
                    if (Directory.Exists(mirrorDir))
                    {
                        string[] javaFiles = Directory.GetFiles(mirrorDir, "*.java", SearchOption.AllDirectories);
                        foreach (string jf in javaFiles)
                        {
                            string jContent = File.ReadAllText(jf, Encoding.UTF8);
                            if (!Regex.IsMatch(jContent, @"@requirement\s+REQ-[A-Z]+-\d+"))
                            {
                                result.Findings.Add(new Finding
                                {
                                    RuleId = "SPEC-004",
                                    Severity = "FATAL",
                                    LineNumber = 1,
                                    ColumnNumber = 1,
                                    Message = string.Format("Core domain service '{0}' is missing mandatory @requirement REQ-* traceability annotation.", Path.GetFileName(jf)),
                                    ContextSnippet = jf
                                });
                            }
                        }
                    }

                    // =========================================================================
                    // PHASE 6: Physical Execution Receipt Gate (PROC-004)
                    // =========================================================================
                    string dossierPath = Path.Combine(projectRoot, @"docs\audit_evidence_dossier.md");
                    if (File.Exists(dossierPath))
                    {
                        string dossierContent = File.ReadAllText(dossierPath, Encoding.UTF8);
                        string auditRunsDir = Path.Combine(projectRoot, @"audit\runs");

                        bool claimsCodex = dossierContent.IndexOf("OpenAI Codex", StringComparison.OrdinalIgnoreCase) >= 0;
                        bool claimsClaude = dossierContent.IndexOf("Anthropic Claude", StringComparison.OrdinalIgnoreCase) >= 0;

                        if (claimsCodex || claimsClaude)
                        {
                            if (!Directory.Exists(auditRunsDir) || Directory.GetDirectories(auditRunsDir).Length == 0)
                            {
                                result.Findings.Add(new Finding
                                {
                                    RuleId = "PROC-004",
                                    Severity = "FATAL",
                                    LineNumber = 1,
                                    ColumnNumber = 1,
                                    Message = "Audit dossier claims external AI cross-verification, but no physical execution receipts exist in audit/runs/!",
                                    ContextSnippet = dossierPath
                                });
                            }
                        }
                    }
                }

            // =========================================================================
            // PHASE 7: Heavy Track Codex Draft Gate (PROC-005)
            // =========================================================================
            bool isHeavyTrack = isSsotFile ||
                               targetFileName.Contains("verifysrs_") ||
                               targetNormPath.Contains("domain_target");

            if (isHeavyTrack)
            {
                        string auditRunsDir = Path.Combine(projectRoot, @"audit\runs");
                        bool hasCodexEvidence = false;

                        if (Directory.Exists(auditRunsDir))
                        {
                            string[] runDirs = Directory.GetDirectories(auditRunsDir, "*", SearchOption.AllDirectories);
                            foreach (string rd in runDirs)
                            {
                                string codexReport = Path.Combine(rd, "codex_report.txt");
                                string codexAudit = Path.Combine(rd, "codex_astra_audit.md");
                                string codexReceipt = Path.Combine(rd, "codex_receipt.json");
                                string manifestJson = Path.Combine(rd, "manifest.json");

                                if (File.Exists(codexReceipt) && new FileInfo(codexReceipt).Length > 0)
                                {
                                    try
                                    {
                                        string receiptText = File.ReadAllText(codexReceipt, Encoding.UTF8);
                                        if (receiptText.IndexOf("\"schema_version\": \"2.0\"", StringComparison.OrdinalIgnoreCase) >= 0 &&
                                            receiptText.IndexOf("\"exit_code\": 0", StringComparison.OrdinalIgnoreCase) >= 0)
                                        {
                                            // Check blob sha if present
                                            Match shaMatch = Regex.Match(receiptText, @"""staged_blob_sha256""\s*:\s*""([a-fA-F0-9]{64})""");
                                            if (shaMatch.Success)
                                            {
                                                using (var sha = System.Security.Cryptography.SHA256.Create())
                                                {
                                                    string actualSha = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(filePath))).Replace("-", "").ToLowerInvariant();
                                                    if (!string.Equals(shaMatch.Groups[1].Value, actualSha, StringComparison.OrdinalIgnoreCase))
                                                    {
                                                        continue;
                                                    }
                                                }
                                            }

                                            if ((File.Exists(codexReport) && new FileInfo(codexReport).Length > 0) ||
                                                (File.Exists(codexAudit) && new FileInfo(codexAudit).Length > 0))
                                            {
                                                hasCodexEvidence = true;
                                                break;
                                            }
                                        }
                                    }
                                    catch {}
                                }
                                else if (File.Exists(codexReport) && new FileInfo(codexReport).Length > 0)
                                {
                                    hasCodexEvidence = true;
                                    break;
                                }
                                else if (File.Exists(codexAudit) && new FileInfo(codexAudit).Length > 0)
                                {
                                    hasCodexEvidence = true;
                                    break;
                                }
                                else if (File.Exists(manifestJson))
                                {
                                    string manifestText = File.ReadAllText(manifestJson, Encoding.UTF8);
                                    if (manifestText.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0)
                                    {
                                        hasCodexEvidence = true;
                                        break;
                                    }
                                }
                            }
                        }

                        if (!hasCodexEvidence)
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "PROC-005",
                                Severity = "FATAL",
                                LineNumber = 1,
                                ColumnNumber = 1,
                                Message = string.Format("Heavy Track asset '{0}' modification requires co-staged Codex receipt and report in audit/runs/.", Path.GetFileName(filePath)),
                                ContextSnippet = filePath
                            });
                        }
                    }

                    // =========================================================================
                    // PHASE 8: Tracked Trace Log & Incident Reconciliation Gate (PROC-006)
                    // =========================================================================
                    string traceLogPath = Path.Combine(projectRoot, @"logs\incident_execution_trace.log");
                    if (!File.Exists(traceLogPath) || new FileInfo(traceLogPath).Length == 0)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "PROC-006",
                            Severity = "FATAL",
                            LineNumber = 1,
                            ColumnNumber = 1,
                            Message = "Execution trace log 'logs/incident_execution_trace.log' is missing or 0-byte. Fail-Closed verification required.",
                            ContextSnippet = traceLogPath
                        });
                    }
                    else
                    {
                        string ledgerPath = Path.Combine(projectRoot, @"logs\incident_history_ledger.md");
                        string ledgerContent = File.Exists(ledgerPath) ? File.ReadAllText(ledgerPath, Encoding.UTF8) : "";

                        string[] traceLines = File.ReadAllLines(traceLogPath, Encoding.UTF8);
                        foreach (string tl in traceLines)
                        {
                            string trimmed = tl.Trim();
                            if (trimmed.IndexOf("[STATUS: FAIL]", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                // Check if this failure signature is resolved in incident_history_ledger.md
                                bool isReconciled = false;
                                if (!string.IsNullOrEmpty(ledgerContent))
                                {
                                    // Extract error code if present: [CODE: XXX]
                                    int codeIdx = trimmed.IndexOf("[CODE:");
                                    if (codeIdx >= 0)
                                    {
                                        int endIdx = trimmed.IndexOf("]", codeIdx);
                                        if (endIdx > codeIdx)
                                        {
                                            string errCode = trimmed.Substring(codeIdx + 6, endIdx - codeIdx - 6).Trim();
                                            if (!string.IsNullOrEmpty(errCode) && errCode != "UNKNOWN")
                                            {
                                                int errPos = ledgerContent.IndexOf(errCode, StringComparison.OrdinalIgnoreCase);
                                                if (errPos >= 0)
                                                {
                                                    // Verify that within the enclosing incident section, status is RESOLVED
                                                    int nextIncidentPos = ledgerContent.IndexOf("### ", errPos + 1);
                                                    if (nextIncidentPos < 0) nextIncidentPos = ledgerContent.Length;
                                                    int prevIncidentPos = ledgerContent.LastIndexOf("### ", errPos);
                                                    if (prevIncidentPos < 0) prevIncidentPos = 0;

                                                    string section = ledgerContent.Substring(prevIncidentPos, nextIncidentPos - prevIncidentPos);
                                                    bool hasResolved = Regex.IsMatch(section, @"\bRESOLVED(_[A-Z_]+)?\b", RegexOptions.IgnoreCase);
                                                    bool hasUnresolved = Regex.IsMatch(section, @"\bUNRESOLVED\b", RegexOptions.IgnoreCase);
                                                    if (hasResolved && !hasUnresolved)
                                                    {
                                                        isReconciled = true;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                if (!isReconciled)
                                {
                                    result.Findings.Add(new Finding
                                    {
                                        RuleId = "PROC-006",
                                        Severity = "FATAL",
                                        LineNumber = 1,
                                        ColumnNumber = 1,
                                        Message = string.Format("Unreconciled failure in trace log: '{0}'. Registration in incident_history_ledger.md required.", trimmed),
                                        ContextSnippet = traceLogPath
                                    });
                                    break; // Report first unmapped failure
                                }
                            }
                        }
                    }

                    // =========================================================================
                    // PHASE 9: Orchestrator Self-Restraint & Audit Linkage Gate (PROC-007)
                    // =========================================================================
                    if (isHeavyTrack)
                    {
                        // Check 9-A: Physical existence of fresh and un-failed audit execution evidence (<24h)
                        string auditRunsDir = Path.Combine(projectRoot, "audit", "runs");
                        string docsAuditRunsDir = Path.Combine(projectRoot, "docs", "audit_runs");
                        bool hasRecentAuditLog = false;
                        DateTime nowUtc = DateTime.UtcNow;
                        DateTime thresholdTime = nowUtc.AddHours(-24);
                        DateTime maxFutureTime = nowUtc.AddMinutes(10); // Clock skew protection

                        if (Directory.Exists(auditRunsDir))
                        {
                            string[] rDirs = Directory.GetDirectories(auditRunsDir, "*", SearchOption.AllDirectories);
                            foreach (string rd in rDirs)
                            {
                                DirectoryInfo dInfo = new DirectoryInfo(rd);
                                if (dInfo.LastWriteTimeUtc >= thresholdTime && dInfo.LastWriteTimeUtc <= maxFutureTime)
                                {
                                    string[] logFiles = Directory.GetFiles(rd, "*.*");
                                    foreach (string lf in logFiles)
                                    {
                                        if (lf.EndsWith(".txt") || lf.EndsWith(".md") || lf.EndsWith(".json"))
                                        {
                                            FileInfo fi = new FileInfo(lf);
                                            if (fi.Length > 0)
                                            {
                                                try
                                                {
                                                    string logContent = File.ReadAllText(lf, Encoding.UTF8);
                                                    // Ensure it is not an unhandled fatal run
                                                    if (logContent.IndexOf("[FATAL]", StringComparison.OrdinalIgnoreCase) < 0 &&
                                                        logContent.IndexOf("status: FAILED", StringComparison.OrdinalIgnoreCase) < 0)
                                                    {
                                                        hasRecentAuditLog = true;
                                                        break;
                                                    }
                                                }
                                                catch {}
                                            }
                                        }
                                    }
                                }
                                if (hasRecentAuditLog) break;
                            }
                        }

                        if (!hasRecentAuditLog && Directory.Exists(docsAuditRunsDir))
                        {
                            string[] rDirs = Directory.GetDirectories(docsAuditRunsDir, "*", SearchOption.AllDirectories);
                            foreach (string rd in rDirs)
                            {
                                DirectoryInfo dInfo = new DirectoryInfo(rd);
                                if (dInfo.LastWriteTimeUtc >= thresholdTime && dInfo.LastWriteTimeUtc <= maxFutureTime)
                                {
                                    string doneFile = Path.Combine(rd, ".done");
                                    string reportMd = Path.Combine(rd, "report.md");
                                    if (File.Exists(doneFile) && new FileInfo(doneFile).Length > 0)
                                    {
                                        hasRecentAuditLog = true;
                                        break;
                                    }
                                    else if (File.Exists(reportMd) && new FileInfo(reportMd).Length > 0)
                                    {
                                        try
                                        {
                                            string repContent = File.ReadAllText(reportMd, Encoding.UTF8);
                                            if (repContent.IndexOf("ExitCode: 1", StringComparison.OrdinalIgnoreCase) < 0)
                                            {
                                                hasRecentAuditLog = true;
                                                break;
                                            }
                                        }
                                        catch {}
                                    }
                                }
                            }
                        }

                        if (!hasRecentAuditLog)
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "PROC-007",
                                Severity = "FATAL",
                                LineNumber = 1,
                                ColumnNumber = 1,
                                Message = "Orchestrator self-restraint violation: SSOT/Heavy Track modifications require fresh (<24h) non-failing external audit execution logs in audit/runs/ or docs/audit_runs/.",
                                ContextSnippet = filePath
                            });
                        }
                    }

            // =========================================================================
            // PHASE 10: Domain Specification Schema & IDOR Gate (Integrated Deterministic Rules)
            // =========================================================================
            if (filePath.EndsWith(".md", StringComparison.OrdinalIgnoreCase) && !filePath.Contains("_KO") && !filePath.Contains("_ko"))
            {
                string fullDocText = Encoding.UTF8.GetString(rawBytes);

                // 10-1. [RULE-FMT-01] Markdown Syntax & Strikethrough Protection (Unspaced Tilde)
                var tildeMatches = Regex.Matches(fullDocText, @"([^\s`])~([^\s`])");
                foreach (Match m in tildeMatches)
                {
                    int idx = m.Index;
                    string before = fullDocText.Substring(0, idx);
                    int codeBlockCount = Regex.Matches(before, @"```").Count;
                    if (codeBlockCount % 2 == 0)
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "RULE-FMT-01",
                            Severity = "FATAL",
                            LineNumber = 1,
                            ColumnNumber = 1,
                            Message = string.Format("Unspaced tilde taboo violated: '{0}' (Required format: ' ~ ')", m.Value),
                            ContextSnippet = m.Value
                        });
                    }
                }

                // 10-2. [RULE-FMT-02] Unfinalized Placeholders (TODO, TBD, 未定)
                var todoMatches = Regex.Matches(fullDocText, @"(?i)\b(TODO|TBD|FIXME)\b|(未定|未確定|追って決定)");
                foreach (Match m in todoMatches)
                {
                    int lineIdx = fullDocText.Substring(0, m.Index).Split('\n').Length;
                    result.Findings.Add(new Finding
                    {
                        RuleId = "RULE-FMT-02",
                        Severity = "WARN",
                        LineNumber = lineIdx,
                        ColumnNumber = 1,
                        Message = string.Format("Unfinalized placeholder detected: '{0}'", m.Value),
                        ContextSnippet = m.Value
                    });
                }

                // 10-3. [RULE-REQ-03] 5 Mandatory Sections Enforcement per Requirement Block
                var reqMatches = Regex.Matches(fullDocText, @"(?m)^#{3,4}\s+\[(REQ-[A-Z0-9_-]+)\]");
                var mandatorySections = new Dictionary<string, string>
                {
                    { "入力", @"-\s*\*\*入力.*?\*\*:" },
                    { "処理", @"-\s*\*\*処理\*\*:" },
                    { "出力", @"-\s*\*\*出力\*\*:" },
                    { "例外処理", @"-\s*\*\*例外処理\*\*:" },
                    { "完了基準 (DoD)", @"-\s*\*\*完了基準\s*\(DoD\)\*\*:" }
                };

                for (int r = 0; r < reqMatches.Count; r++)
                {
                    string reqId = reqMatches[r].Groups[1].Value;
                    int startIdx = reqMatches[r].Index;
                    int endIdx = (r + 1 < reqMatches.Count) ? reqMatches[r + 1].Index : fullDocText.Length;
                    string reqBlock = fullDocText.Substring(startIdx, endIdx - startIdx);
                    int reqLine = fullDocText.Substring(0, startIdx).Split('\n').Length;

                    foreach (var kvp in mandatorySections)
                    {
                        if (!Regex.IsMatch(reqBlock, kvp.Value))
                        {
                            result.Findings.Add(new Finding
                            {
                                RuleId = "RULE-REQ-03",
                                Severity = "FATAL",
                                LineNumber = reqLine,
                                ColumnNumber = 1,
                                Message = string.Format("Requirement '{0}' is missing mandatory section: '**{1}**'", reqId, kvp.Key),
                                ContextSnippet = reqId
                            });
                        }
                    }

                    // 10-4. [RULE-SEC-04] IDOR Security Gate (No Raw Client-Supplied ID Parameters)
                    if (reqId.StartsWith("REQ-STORE-") || reqId.StartsWith("REQ-STAFF-") || reqId.StartsWith("REQ-MEMBER-"))
                    {
                        var inputMatch = Regex.Match(reqBlock, @"-\s*\*\*入力.*?\*\*:(.*?)(?=-\s*\*\*(処理|出力|例外処理|完了基準)\*\*:|$)", RegexOptions.Singleline);
                        if (inputMatch.Success)
                        {
                            string inputContent = inputMatch.Groups[1].Value;
                            string[] inputLines = inputContent.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);
                            foreach (string rawLine in inputLines)
                            {
                                string lTrim = rawLine.Trim();
                                if (string.IsNullOrEmpty(lTrim)) continue;

                                var idMatch = Regex.Match(lTrim, @"(?i)\b(owner_?id|member_?id)\b");
                                if (idMatch.Success)
                                {
                                    bool isSafe = lTrim.Contains("リクエストパラメータから一切受け取らず") ||
                                                  lTrim.Contains("SecurityContext") ||
                                                  lTrim.Contains("完全禁止") ||
                                                  lTrim.Contains("JWT") ||
                                                  lTrim.Contains("クライアント指定不可") ||
                                                  lTrim.Contains("セッションから取得");

                                    bool isDangerous = lTrim.Contains("受け取る") ||
                                                       lTrim.Contains("受け付ける") ||
                                                       lTrim.Contains("クライアント") ||
                                                       lTrim.Contains("パラメータ") ||
                                                       lTrim.Contains("リクエスト") ||
                                                       lTrim.Contains("入力") ||
                                                       lTrim.Contains("必須") ||
                                                       lTrim.Contains("任意");

                                    if (!isSafe && isDangerous)
                                    {
                                        result.Findings.Add(new Finding
                                        {
                                            RuleId = "RULE-SEC-04",
                                            Severity = "FATAL",
                                            LineNumber = reqLine,
                                            ColumnNumber = 1,
                                            Message = string.Format("Insecure Direct Object Reference (IDOR) risk in '{0}': Client-supplied parameter '{1}' detected in line: {2}", reqId, idMatch.Value, lTrim),
                                            ContextSnippet = lTrim
                                        });
                                    }
                                }
                            }
                        }
                    }
                }

                // 10-5. [RULE-FSM-01] Finite State Machine (FSM) Transition Inversion Gate (RFC-FUNC-04)
                var fsmInversionMatches = Regex.Matches(fullDocText, @"(?i)\b(CONFIRMED\s*(?:➔|->|→)\s*SUBMITTED|REJECTED\s*(?:➔|->|→)\s*CONFIRMED|CONFIRMED\s*(?:➔|->|→)\s*(?:取消|削除)|REJECTED\s*(?:➔|->|→)\s*(?:取消|削除))\b");
                foreach (Match m in fsmInversionMatches)
                {
                    string before = fullDocText.Substring(0, m.Index);
                    int lineIdx = before.Split('\n').Length;
                    string[] splitLines = fullDocText.Substring(0, m.Index + m.Length).Split('\n');
                    string lineText = splitLines.Length > 0 ? splitLines[splitLines.Length - 1] : "";
                    if (!lineText.Contains("禁止") && !lineText.Contains("不可") && !lineText.Contains("不成立"))
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "RULE-FSM-01",
                            Severity = "FATAL",
                            LineNumber = lineIdx,
                            ColumnNumber = 1,
                            Message = string.Format("Invalid FSM State Transition detected: '{0}'. Transitions must adhere to lifecycle rules (CONFIRMED/REJECTED are terminal).", m.Value),
                            ContextSnippet = m.Value
                        });
                    }
                }

                // 10-6. [RULE-LOCK-01] Pessimistic Lock Ordering Hierarchy Gate (CC-LOCK-01 & RFC-FUNC-04)
                // Enforces Tier 1 (member) ➔ Tier 2 (store) ➔ Tier 3 (store_staff) ➔ Tier 4 (contract_history/shift/attendance)
                var lockInversionMatches = Regex.Matches(fullDocText, @"(?i)(?:ロック|FOR\s+(?:UPDATE|SHARE))[^.\n\r]*?\b(store\s*(?:➔|->|→)\s*member|store_staff\s*(?:➔|->|→)\s*store|contract_history\s*(?:➔|->|→)\s*store_staff|shift\s*(?:➔|->|→)\s*store_staff)\b");
                foreach (Match m in lockInversionMatches)
                {
                    int lineIdx = fullDocText.Substring(0, m.Index).Split('\n').Length;
                    string snippet = m.Value.Trim();
                    if (!snippet.Contains("禁止") && !snippet.Contains("避ける") && !snippet.Contains("逆転"))
                    {
                        result.Findings.Add(new Finding
                        {
                            RuleId = "RULE-LOCK-01",
                            Severity = "FATAL",
                            LineNumber = lineIdx,
                            ColumnNumber = 1,
                            Message = string.Format("Pessimistic lock order inversion detected: '{0}'. Lock hierarchy must strictly follow: member ➔ store ➔ store_staff ➔ contract_history/shift/attendance.", snippet),
                            ContextSnippet = snippet
                        });
                    }
                }
            }

            // =========================================================================
            // Evaluation & Console Output
            // =========================================================================
            int fatalCount = 0;
            int warnCount = 0;

            Console.WriteLine(string.Format("=== [SRS Unified Master Linter v1.2] Analyzing: {0} ===", Path.GetFileName(filePath)));
            Console.WriteLine(string.Format("Total Lines: {0} | Total Bytes: {1}", lines.Length, rawBytes.Length));

            foreach (var f in result.Findings)
            {
                if (f.Severity == "FATAL") fatalCount++;
                if (f.Severity == "WARN") warnCount++;

                Console.WriteLine(string.Format("[{0}] [{1}] Line {2}, Col {3}: {4}",
                    f.Severity, f.RuleId, f.LineNumber, f.ColumnNumber, f.Message));
                if (!string.IsNullOrEmpty(f.ContextSnippet))
                {
                    Console.WriteLine(string.Format("   Evidence: {0}", f.ContextSnippet));
                }
            }

            result.FatalCount = fatalCount;
            result.WarningCount = warnCount;

            if (fatalCount > 0)
            {
                Console.WriteLine(string.Format(">>> VERDICT: FAIL (FATAL Violations: {0}, Warnings: {1})", fatalCount, warnCount));
                result.ExitCode = 1;
            }
            else if (warnCount > 0)
            {
                Console.WriteLine(string.Format(">>> VERDICT: PASS WITH WARNINGS (Warnings: {0})", warnCount));
                result.ExitCode = 0;
            }
            else
            {
                Console.WriteLine(">>> VERDICT: PASS (Clean Integrity, Zero Defects)");
                result.ExitCode = 0;
            }

            return result;
        }

        private static void CheckBlockDuplicate(string blockText, int lineNum, Dictionary<string, int> seen, VerificationResult result)
        {
            // Normalize spaces
            string clean = Regex.Replace(blockText, @"\s+", " ").Trim();
            if (clean.Length < 100) return; // Skip small blocks

            // Ignore markdown tables and code blocks for duplicate checks
            if (clean.StartsWith("|") || clean.StartsWith("```")) return;

            if (seen.ContainsKey(clean))
            {
                result.Findings.Add(new Finding
                {
                    RuleId = "INTEGRITY-DUP-001",
                    Severity = "WARN",
                    LineNumber = lineNum,
                    ColumnNumber = 1,
                    Message = string.Format("Identical text block (>100 chars) detected. Previously seen at line {0}.", seen[clean]),
                    ContextSnippet = clean.Substring(0, Math.Min(60, clean.Length)) + "..."
                });
            }
            else
            {
                seen[clean] = lineNum;
            }
        }

        private static List<string> ParseCsvRow(string row)
        {
            List<string> columns = new List<string>();
            if (row == null) return columns;

            StringBuilder current = new StringBuilder();
            bool inQuotes = false;

            for (int i = 0; i < row.Length; i++)
            {
                char c = row[i];
                if (c == '\"')
                {
                    if (inQuotes && i + 1 < row.Length && row[i + 1] == '\"')
                    {
                        current.Append('\"');
                        i++; // Skip escaped quote
                    }
                    else
                    {
                        inQuotes = !inQuotes;
                    }
                }
                else if (c == ',' && !inQuotes)
                {
                    columns.Add(current.ToString());
                    current.Length = 0;
                }
                else
                {
                    current.Append(c);
                }
            }
            columns.Add(current.ToString());
            return columns;
        }

        private static List<byte[]> SplitBytesIntoLines(byte[] bytes)
        {
            List<byte[]> lines = new List<byte[]>();
            int start = 0;
            for (int i = 0; i < bytes.Length; i++)
            {
                if (bytes[i] == 0x0A) // LF
                {
                    int len = i - start;
                    byte[] line = new byte[len];
                    Array.Copy(bytes, start, line, 0, len);
                    lines.Add(line);
                    start = i + 1;
                }
            }
            if (start < bytes.Length)
            {
                int len = bytes.Length - start;
                byte[] line = new byte[len];
                Array.Copy(bytes, start, line, 0, len);
                lines.Add(line);
            }
            return lines;
        }

        private static DateTime? ExtractMaxDateFromLedger(string path, int timestampCol)
        {
            try
            {
                string[] lines = File.ReadAllLines(path, Encoding.UTF8);
                DateTime? maxDate = null;
                for (int i = 1; i < lines.Length; i++)
                {
                    string row = lines[i].Trim();
                    if (string.IsNullOrEmpty(row)) continue;
                    List<string> cols = ParseCsvRow(row);
                    if (cols.Count > timestampCol)
                    {
                        string rawTs = cols[timestampCol].Trim('\"', ' ').Replace(" - ", " ").Replace("/", "-");
                        DateTime dt;
                        if (DateTime.TryParse(rawTs, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out dt))
                        {
                            if (!maxDate.HasValue || dt > maxDate.Value)
                            {
                                maxDate = dt;
                            }
                        }
                    }
                }
                return maxDate;
            }
            catch
            {
                return null;
            }
        }

        private static string GetContextSnippet(string line, int colIndex, int range)
        {
            if (string.IsNullOrEmpty(line)) return "";
            int start = Math.Max(0, colIndex - range);
            int len = Math.Min(line.Length - start, (range * 2) + 1);
            return line.Substring(start, len).Trim();
        }
    }
}
