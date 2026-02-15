# ...existing code...
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/birdfeeder-sa.json"
FIREBASE_PROJECT_ID = "birdfeeder-b6224"

# Firestore paths (use ONE canonical value)
ENERGY_DATA_COLLECTION = "logs/energy/data"
SIGHTING_COLLECTION = "logs/sightings/data"
STREAMING_STATUS_PATH = "status/streaming_enabled"

# Storage bucket
STORAGE_BUCKET = f"{FIREBASE_PROJECT_ID}.firebasestorage.app"  # verify in Firebase Console