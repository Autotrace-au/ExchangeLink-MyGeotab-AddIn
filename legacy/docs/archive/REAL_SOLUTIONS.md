# (Archive) Exchange Calendar Processing Strategy Narrative

Original narrative retained to capture rationale behind Container App solution and limitations of Microsoft's platform.

## Core Assertions
- Set-CalendarProcessing only available in PowerShell
- Graph & EWS lack equivalent configuration APIs
- Azure Automation concurrency insufficient for scaling

## Outcome
Adopted Azure Container Apps (PowerShell 7) with HTTP endpoints as primary scalable mechanism for calendar processing.
