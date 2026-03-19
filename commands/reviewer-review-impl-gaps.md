---
description: (linhvu) review the code base and the changes vs plan
---

## Procedure:
- First enter the Plan mode
- review the changesets, current code base, existing documents and the plan file here $ARGUMENTS then identify the gaps between the original plan and code changes has been made, divide issues into 3 groups:

    - block: A bug that should be fixed before merging
    - nit: A minor issue, worth fixing but not blocking
    - pre-existing: A bug that exists in the codebase but was not introduced by recent code changes

If no code change is requires, or code change is small (nitpick, eg typo), let fix it automatically and output the text "REVIEWER_APPROVED" on a single new line. In this case, exit here, don't create a new plan file.

Otherwise, create a plan to address major issues, make sure to include the update documents, tests. For each issue, explicitly note the criterias for passing.
Make sure to include on the Context section of the final plan file:
- the gap list in the plan
- the file path of the original plan