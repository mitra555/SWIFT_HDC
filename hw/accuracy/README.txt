HDC video pipeline -- accuracy numbers for the paper

Needs only Python 3 and internet the first time. Run from this folder:

    python run_accuracy.py

It downloads the KTH dataset into ./KTH (~980 MB, once), installs numpy + OpenCV 4.x if
missing, extracts features (cached), runs every mode twice and writes results/RESULTS.md.

Unattended (survives closing the terminal):

    nohup python run_accuracy.py > run.log 2>&1 &

Already have KTH somewhere?  python run_accuracy.py --data /path/to/folder-with-boxing-etc
