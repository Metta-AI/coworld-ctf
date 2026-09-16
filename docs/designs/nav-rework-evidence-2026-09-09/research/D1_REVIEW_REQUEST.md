# D1 actual code review

After finishing prefix-sharing report, review the current body_nav diff against D1-parent-body_nav.nim (D0 checkpoint8fe2cbad). D1 only carries kernelIndex and passes it to addVisibleCell, preserves stamp guard/float addition. D1_PREREG.md contains the negative counter-hypothesis: index work now happens on repeated visits too. Focused15/15+29/29 pass; m5a3pairs and m8i3072quality are running. Please write D1_CODE_REVIEW.md, no source edits. Verify side-cell indices, origin index, all signs/bounds and every call site.
