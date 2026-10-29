-- Remote links (a QR code that opens a deck's remote without signing in)
-- carry the deck's remote epoch; raising it ends every link given out so
-- far ("Neuen Code erzeugen").

ALTER TABLE presentations ADD COLUMN remote_epoch integer NOT NULL DEFAULT 0;
