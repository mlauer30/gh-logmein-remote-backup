# New Checking Workflow
## Count files for given PC subfolder, use command: 

```powershell
(Get-ChildItem -Path . -File -Recurse).Count 
# or
(gci . -file -r).count
```

```bash
find . -type f | wc -l
```
---
## Check difference in file total after copy is complete
Next use the copy-log-*.txt to determine if difference is significant enough for restaging or to determine if a PC logged off during a copy to Q:\
```bash
cat copy-log<tab> | grep 'files:'
```

Reference staging report for PCs that needed to be restaged
```bash
cat stage<tab> | grep 'count' 
```

