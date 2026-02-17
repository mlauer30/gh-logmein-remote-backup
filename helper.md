# New Checking Workflow
## Count files for given PC subfolder, use command: 
```powershell
(Get-ChildItem -Path . -File -Recurse).Count 
```
---
## Check difference in file total after copy is complete
Next use the copy-log-*.txt to determine if difference is significant enough for restaging or to determine if a PC logged off during a copyto Q:\
