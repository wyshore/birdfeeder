# Phase 5: App Redesign - Activity & Catalog

**Goal:** Restructure app to focus on bird activity tracking and species profiles.

## New Information Architecture

### Activity Screen (Replaces Gallery)
Shows recent **unidentified** sightings. Organized by day in subsections. 

**UI:**
- Grid layout (similar to current gallery)
- Each card shows: thumbnail, date/time
- Tap to open detail view
- Detail view has: full image, "Identify as..." button, delete button
- When identified → moves to Catalog, removed from Activity
- When all birds from a given day have been identified and moved to catalog, user can       select "clear" which deletes remaining photos from that day. 

**Data source:** Firestore query `logs/motion_captures/data` where `identified = false`

### Catalog Screen (Enhanced)
Shows all **identified** bird species.

**UI:**
- List view (current design is good)
- Each card shows: species name, primary photo, sighting count
- Sorted by sighting count (most frequent first) or last seen
- Tap to open Bird Profile

### Bird Profile Screen (NEW)
Full details for a specific species.

**Sections:**
1. **Header:** Species name, primary photo
2. **Photo Grid:** All sightings for this species (tappable for fullscreen)
3. **Stats:**
   - Total sightings: `count`
   - First seen: `min(timestamp)`
   - Last seen: `max(timestamp)`
   - Average time of day: Calculate from timestamps, show as a histogram
   - Average time of year: show as a histogram by 2 week increments
   - Frequency: Sightings per day/week
4. **Description:** Text field (user editable or API lookup later)
5. **Actions:** Edit species name, delete species, unlink sightings

## Data Model Changes

### Update Sighting Model
Add fields to sighting documents:
- `identified: bool` (default false)
- `species_id: string` (null if not identified)
- `species_name: string` (denormalized for easy display)

### Create Species Collection
New Firestore collection: `catalog/species/entries`

Each species document:
```
{
  id: auto-generated
  common_name: string
  description: string (optional)
  primary_image_url: string
  sighting_count: number (updated on identification)
  first_seen: timestamp
  last_seen: timestamp
}
```

## Implementation Steps

### 1. Update Firestore Schema
- Add migration script to add `identified: false` to existing sightings
- Create initial species documents for any existing catalog entries

### 2. Update Sighting Model (Flutter)
- Add new fields
- Update `fromFirestore` factory

### 3. Create Species Model (Flutter)
- New model class
- Firestore serialization

### 4. Build Activity Screen
- Replace gallery_screen.dart or create activity_screen.dart
- Query only unidentified sightings
- Implement "Identify as..." flow (shows species picker)
- On identify: update sighting doc, increment species sighting_count

### 5. Enhance Catalog Screen
- Query from `catalog/species/entries` instead of hardcoded
- Update sorting logic

### 6. Build Bird Profile Screen
- New screen: bird_profile_screen.dart
- Query all sightings where `species_id = this_species`
- Calculate stats from sighting data
- Implement edit/delete actions

## Success Criteria
✓ Activity screen shows only unidentified sightings
✓ Can identify sightings and move to catalog
✓ Bird profiles show stats and all photos
✓ Data model migration successful
✓ No data loss during transition
