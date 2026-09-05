# PSSync

PSSync is a PowerShell directory synchronization utility inspired by the behavior of `rsync`.

It synchronizes files and directories from a source tree to a destination tree using file timestamps to determine whether an existing destination file needs to be updated.

## Features

- Copies files that are missing from the destination.
- Updates destination files when the source file is newer.
- Leaves destination files alone when they are the same age or newer.
- Creates destination directories required by the source.
- Identifies destination-only files and directories.
- Optional `-Mirror` mode removes destination-only files and directories.
- Supports PowerShell's `-WhatIf` behavior for previewing planned changes.
- Supports `-ChangesOnly` to suppress noisy no-change messages.
- Displays progress while enumerating and analyzing large directory trees.
- Detects file/directory conflicts before modifying the destination.
- Reports file-system operation errors and provides a final summary.

## Requirements

- Windows PowerShell 5.1 or later
- Pester 3.4.0 or compatible Pester version for running the included tests

## Installation

PSSync is currently distributed as a PowerShell module file.

Copy `PSSync.psm1` to a location on your PowerShell module path, or import it directly from the project directory.

For example:

```powershell
Import-Module .\PSSync.psm1 -Force
```

The module exports the `PSSync` function.

## Basic Usage

```powershell
PSSync "C:\Source" "D:\Destination"
```

The source must be an existing directory. The destination directory is created when it does not already exist.

## Mirror Mode

Use `-Mirror` when the destination should also be cleaned of items that do not exist in the source:

```powershell
PSSync "C:\Source" "D:\Destination" -Mirror
```

Without `-Mirror`, destination-only files and directories are retained.

**Use `-Mirror` carefully.** It can permanently delete destination files and directories.

## WhatIf

Use `-WhatIf` to preview the synchronization without modifying the file system:

```powershell
PSSync "C:\Source" "D:\Destination" -WhatIf
```

With `-Mirror`:

```powershell
PSSync "C:\Source" "D:\Destination" -Mirror -WhatIf
```

The WhatIf output reports the operations that would be performed and provides a summary.

## ChangesOnly

Large directory trees can produce a lot of output for files that do not need to change.

Use `-ChangesOnly` to suppress those no-change messages:

```powershell
PSSync "C:\Source" "D:\Destination" -ChangesOnly
```

With `-ChangesOnly`:

- `UNCHANGED` messages are suppressed during normal operation.
- `WOULD LEAVE ALONE` messages are suppressed during `-WhatIf`.
- Copies, updates, deletions, errors, and other actionable messages remain visible.
- The final summary still includes the unchanged/no-action counts.

`-ChangesOnly` changes output only; it does not change synchronization behavior.

## Synchronization Rules

For each source item:

1. A missing destination directory is created.
2. A missing source file is copied.
3. An existing destination file is updated when the source `LastWriteTimeUtc` is newer.
4. A destination file that is the same age or newer is left unchanged.
5. Destination-only files are retained unless `-Mirror` is specified.
6. Destination-only directories are retained unless `-Mirror` is specified.
7. Mirror directory cleanup is performed from the deepest directory toward the destination root.
8. File/directory conflicts at the same relative path are detected before synchronization begins.

## Progress Reporting

PSSync displays progress during operations that can take significant time on large directory trees.

The progress stages include:

- Enumerating source files
- Enumerating source directories
- Enumerating destination files
- Enumerating destination directories
- Determining workload
- Checking for file/directory conflicts
- Analyzing source and destination

The analysis stage provides a percentage based on the items analyzed relative to the synchronization workload.

## Output

Normal execution reports operations such as:

```text
COPIED: folder\newfile.txt
UPDATED: folder\changedfile.txt
UNCHANGED: folder\existingfile.txt
DELETED: oldfile.txt
DELETED DIRECTORY: oldfolder
EXTRANEOUS: retained-destination-file.txt
```

The final summary reports counts for:

- Copied files
- Updated files
- Unchanged files
- Deleted files
- Deleted directories
- Errors

## Error Handling

Source validation and other pre-synchronization validation failures produce terminating errors.

Individual file-system operation failures are reported as errors and included in the final error count. PSSync continues processing other planned operations where possible.

## Limitations

PSSync currently:

- Uses `LastWriteTimeUtc` rather than comparing file contents.
- Does not perform hash-based file comparison.
- Does not provide file or directory include/exclude filters.
- Does not provide external logging.
- Is intended primarily as a straightforward directory synchronization utility rather than a full replacement for mature synchronization tools.

## Testing

The project includes a Pester test suite covering the core synchronization behavior, including:

- Missing file copies
- Newer-file updates
- Unchanged and newer destination files
- Mirror file and directory deletion
- WhatIf behavior
- ChangesOnly output
- Nested directories
- Empty source/destination scenarios
- File/directory conflicts
- Destination path errors
- Summary and error handling

Run the tests from the project directory with:

```powershell
Remove-Module PSSync -ErrorAction SilentlyContinue
Import-Module .\PSSync.psm1 -Force
Invoke-Pester .\Tests\PSSync.Tests.ps1
```

## Reporting Bugs and Requesting Features

Please use the GitHub repository's **Issues** section to report bugs or request features.

When reporting a problem, include:

- PSSync version
- PowerShell version
- Windows version
- The command that was run
- Whether `-Mirror`, `-WhatIf`, or `-ChangesOnly` was used
- The relevant output or error message
- A description of the expected and actual behavior

Using GitHub Issues keeps reports organized and avoids requiring a personal email address in the project documentation.

## License

A project license has not yet been specified. Add an appropriate license before presenting the repository as an openly licensed project.
