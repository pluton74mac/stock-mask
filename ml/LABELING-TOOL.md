# Checking the labels

Claude labelling agents draw and correct the boxes (see [LABELING.md](LABELING.md)). Your part is to spot-check
them.

1. Ask Claude to refresh the check page, or run this in Terminal from the `stock-mask` folder:

   ```
   ml/.venv/bin/python ml/review.py sheet
   ```

2. Open `ml/data/review/spotcheck.html` in the Finder; it opens in your browser. Each picture is one frame with its
   boxes: blue for bottles, orange for tops (caps), green for cans, purple for cases. Click a picture to see it full
   size.
3. If something looks wrong, tell Claude the frame name under the picture and what is wrong, for example "w2-bay2_f02018:
   the yellow cap on the far right has no box". Claude fixes it with the same tool.

The page and the pictures stay on this Mac, in a folder git leaves out. Don't upload or share them: they show the
storeroom.

**Why not a labelling app?** The plan named CVAT, which needs Docker, and this Mac has none. Label Studio (free,
Apache-2.0) was the stand-in. It was set aside on 2 October 2026, when Claude took over fixing the boxes and a simple
page became enough for checking them. To bring it back, install `label-studio` in its own venv.
