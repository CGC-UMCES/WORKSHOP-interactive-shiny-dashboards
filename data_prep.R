# ==============================================================================
#
#  DATA PREPARATION SCRIPT
#  Baltimore Harbor / Chesapeake Bay Workshop Demo
#
#  Run this script ONCE before the workshop to download, clean, and save
#  all real data files to the data/ folder. The app.R file then loads
#  these pre-processed files at startup instead of the simulated data.
#
#  OUTPUTS (saved to data/):
#    wq_baltimore.csv          - Water quality time series (CBP stations)
#    watersheds_baltimore.gpkg - HUC8 watershed polygons (simplified)
#    nlcd_baltimore.tif        - NLCD land cover raster (clipped + resampled)
#
#  APPROXIMATE RUN TIME: 10-20 minutes depending on connection speed
#  FILE SIZES:            wq ~213KB | watersheds ~696KB | nlcd ~139KB
#
#  PACKAGES NEEDED (in addition to app.R packages):
#    install.packages(c("dataRetrieval", "nhdplusTools", "FedData", "lubridate"))
#
# ==============================================================================

library(dataRetrieval)  # Pull water quality data from EPA/USGS Water Quality Portal
library(nhdplusTools)   # Pull HUC8 watershed boundaries from USGS NHD
library(FedData)        # Download NLCD land cover raster from MRLC
library(sf)             # Vector spatial operations
library(terra)          # Raster operations
library(dplyr)          # Data manipulation
library(tidyr)          # Reshaping
library(readr)          # CSV writing
library(lubridate)      # Date handling
library(purrr)          # map_dfr for station-by-station download loop

# Set working directory to the workshop folder
# Update this path to wherever you unzipped the workshop files
# Or use Session -> Set Working Directory -> To Source File Location in RStudio
setwd("~/Desktop/workshop_files")

# Create output directory if it doesn't exist
if (!dir.exists("data")) dir.create("data")

# Bounding box for the Baltimore / upper Bay region
# Expanded to cover full watershed extents including Chester-Sassafras to the east
bbox <- c(xmin = -77.25, ymin = 38.67, xmax = -75.60, ymax = 39.80)


# ==============================================================================
# PART 1 - WATER QUALITY TIME SERIES
# ------------------------------------------------------------------------------
# Source: EPA Water Quality Portal (WQP) via dataRetrieval package
# Pulls data from the Chesapeake Bay Program monitoring network covering
# Baltimore Harbor and surrounding tidal waters.
#
# Key lessons from initial download:
#   - Dissolved oxygen is named "Dissolved oxygen (DO)" in the WQP, NOT
#     "Dissolved oxygen" - the query will silently return no DO data if wrong
#   - Station names are not in the results CSV, must be pulled separately
#     via whatWQPsites() and joined by MonitoringLocationIdentifier
#   - Many stations are one-off survey sites; we hand-pick 8 long-term
#     monitoring stations with consistent monthly records and good spatial spread
# ==============================================================================

cat("Downloading water quality data from EPA Water Quality Portal...\n")
cat("This may take 5-10 minutes.\n\n")

# Download one station at a time to avoid WQP server timeouts
# A single large query across all stations times out (HTTP 500)
# but individual station queries are fast and reliable
station_ids <- c(
  "CBP_WQX-PAT0176", "CBP_WQX-PAT0285", "CBP_WQX-JON0184",
  "CBP_WQX-GUN0125", "CBP_WQX-PXT0809", "CBP_WQX-CB3.2",
  "CBP_WQX-ET4.2",   "CBP_WQX-XGG8251"
)

params <- c(
  "Dissolved oxygen (DO)",
  "Temperature, water",
  "Salinity",
  "Chlorophyll a"
)

wq_raw <- purrr::map_dfr(station_ids, function(sid) {
  cat("Downloading:", sid, "\n")
  df <- readWQPdata(
    siteid             = sid,
    characteristicName = params,
    startDateLo        = "2015-01-01",
    startDateHi        = "2023-12-31",
    sampleMedia        = "Water"
  )
  # Force all columns to character before binding to avoid type conflicts
  # between stations (WQP returns some numeric columns as double, others as character)
  dplyr::mutate(df, dplyr::across(dplyr::everything(), as.character))
})

cat(paste("Downloaded", nrow(wq_raw), "raw water quality records\n\n"))

# Pull station metadata by site ID - faster and avoids bBox timeout issues
cat("Fetching station metadata...\n")
sites <- whatWQPsites(
  siteid = c(
    "CBP_WQX-PAT0176", "CBP_WQX-PAT0285", "CBP_WQX-JON0184",
    "CBP_WQX-GUN0125", "CBP_WQX-PXT0809", "CBP_WQX-CB3.2",
    "CBP_WQX-ET4.2",   "CBP_WQX-XGG8251"
  )
)

# Hand-picked long-term monitoring stations with good spatial spread:
#   PAT0176  - Patapsco River (lower, near harbor)
#   PAT0285  - Patapsco Upper (upper watershed)
#   JON0184  - Jones Falls
#   GUN0125  - Gunpowder River
#   PXT0809  - Patuxent River
#   CB3.2    - Upper Chesapeake Bay mainstem
#   ET4.2    - Eastern Bay
#   XGG8251  - Back River
#
# Selection criteria:
#   1. All four parameters with roughly monthly sampling (2015-2023)
#   2. Spread across our four HUC8 watersheds
#   3. Long-term stations, not one-off survey sites
station_lookup <- tribble(
  ~station_id,              ~station_name,
  "CBP_WQX-PAT0176",       "Patapsco River",
  "CBP_WQX-PAT0285",       "Patapsco Upper",
  "CBP_WQX-JON0184",       "Jones Falls",
  "CBP_WQX-GUN0125",       "Gunpowder River",
  "CBP_WQX-PXT0809",       "Patuxent River",
  "CBP_WQX-CB3.2",         "Upper Bay",
  "CBP_WQX-ET4.2",         "Eastern Bay",
  "CBP_WQX-XGG8251",       "Back River"
) |>
  left_join(
    sites |>
      select(
        station_id = MonitoringLocationIdentifier,
        lat        = LatitudeMeasure,
        lon        = LongitudeMeasure
      ),
    by = "station_id"
  )

# Recode WQP parameter names to internal app codes
param_recode <- c(
  "Dissolved oxygen (DO)" = "dissolved_oxygen",
  "Temperature, water"    = "temperature",
  "Salinity"              = "salinity",
  "Chlorophyll a"         = "chlorophyll_a"
)

# Clean and reshape to match app.R expected format
# Expected columns: station_id, station_name, lat, lon, date, parameter, value
wq_clean <- wq_raw |>
  filter(MonitoringLocationIdentifier %in% station_lookup$station_id) |>
  select(
    station_id = MonitoringLocationIdentifier,
    date       = ActivityStartDate,
    parameter  = CharacteristicName,
    value      = ResultMeasureValue,
    depth      = ActivityDepthHeightMeasure.MeasureValue
  ) |>
  mutate(
    date  = as.Date(date),
    value = suppressWarnings(as.numeric(value)),
    depth = suppressWarnings(as.numeric(depth))
  ) |>
  # Surface samples only (depth <= 1m or missing depth)
  filter(is.na(depth) | depth <= 1) |>
  # Recode parameter names to internal codes
  mutate(parameter = recode(parameter, !!!param_recode)) |>
  filter(parameter %in% param_recode) |>
  # Remove obviously bad values
  filter(
    !is.na(value),
    !(parameter == "dissolved_oxygen" & (value < 0 | value > 20)),
    !(parameter == "temperature"      & (value < 0 | value > 35)),
    !(parameter == "salinity"         & (value < 0 | value > 35)),
    !(parameter == "chlorophyll_a"    & (value < 0 | value > 500))
  ) |>
  # Monthly aggregate: mean per station per parameter per month
  mutate(date = floor_date(date, "month")) |>
  group_by(station_id, date, parameter) |>
  summarise(value = round(mean(value, na.rm = TRUE), 2), .groups = "drop") |>
  # Join station names and coordinates
  left_join(station_lookup, by = "station_id")

cat(paste(
  "Cleaned water quality data:",
  n_distinct(wq_clean$station_id), "stations,",
  nrow(wq_clean), "monthly records\n"
))

write_csv(wq_clean, "data/wq_baltimore.csv")
cat("Saved: data/wq_baltimore.csv\n\n")


# ==============================================================================
# PART 2 - HUC8 WATERSHED POLYGONS
# ------------------------------------------------------------------------------
# Source: USGS National Hydrography Dataset via nhdplusTools package
# Four HUC8 units covering our study area:
#   02060001 - Upper Chesapeake Bay
#   02060002 - Chester-Sassafras
#   02060003 - Gunpowder-Patapsco
#   02060004 - Severn
#
# Note: these HUC8 units extend beyond our map bounding box - that is fine,
# Leaflet will only display the portion within the map view.
# ==============================================================================

cat("Downloading HUC8 watershed boundaries from USGS NHD...\n")

watersheds_raw <- get_huc(
  id   = c("02060001", "02060002", "02060003", "02060004"),
  type = "huc08"
)

watersheds_clean <- watersheds_raw |>
  transmute(
    huc8      = huc8,
    huc8_name = name,
    area_km2  = round(areasqkm)
  ) |>
  st_transform(4326) |>
  # Simplify geometry to reduce vertex count for faster map rendering
  # dTolerance = 0.001 degrees ~ 100m, preserves overall shape well
  st_simplify(dTolerance = 0.001, preserveTopology = TRUE)

# Clip the Upper Chesapeake Bay and Severn watersheds to remove their
# southern extents below ~38.74 (same southern limit as Chester-Sassafras).
# This keeps all four watersheds at a consistent southern boundary.
clip_box <- st_as_sfc(st_bbox(
  c(xmin = -77.50, ymin = 38.74, xmax = -75.50, ymax = 40.00),
  crs = 4326
))

watersheds_clean <- watersheds_clean |>
  mutate(geometry = case_when(
    huc8 %in% c("02060001", "02060004") ~
      st_intersection(geometry, clip_box),
    TRUE ~ geometry
  )) |>
  st_set_geometry("geometry")

cat(paste(
  "Watershed polygons:",
  nrow(watersheds_clean), "HUC8 units downloaded\n"
))

st_write(watersheds_clean, "data/watersheds_baltimore.gpkg",
         delete_dsn = TRUE, quiet = TRUE)
cat("Saved: data/watersheds_baltimore.gpkg\n\n")


# ==============================================================================
# PART 3 - NLCD LAND COVER RASTER
# ------------------------------------------------------------------------------
# Source: Multi-Resolution Land Characteristics Consortium (MRLC)
# via the FedData package.
#
# The NLCD downloads in NAD83 Albers (EPSG:5070) at 30m resolution.
# We reproject to WGS84 (required by Leaflet), then aggregate to 90m
# (modal resampling preserves integer class codes) to reduce file size
# from ~150MB to ~139KB while keeping the spatial pattern clear.
# ==============================================================================

cat("Downloading NLCD 2021 land cover raster from MRLC...\n")
cat("This may take several minutes.\n\n")

# Define study area as sf polygon for FedData query
# Note: using st_bbox approach avoids NA errors with get_nlcd
study_area <- st_as_sf(
  data.frame(x = c(bbox["xmin"], bbox["xmax"]),
             y = c(bbox["ymin"], bbox["ymax"])),
  coords = c("x", "y"),
  crs = 4326
) |>
  st_bbox() |>
  st_as_sfc() |>
  st_as_sf()

# Download NLCD 2021 land cover clipped to study area
nlcd_raw <- get_nlcd(
  template = study_area,
  label    = "baltimore",
  year     = 2021,
  dataset  = "landcover"
)

# Reproject to WGS84 (Leaflet requires lat/lon)
# method = "near" preserves integer class codes (no interpolation)
nlcd_wgs <- project(nlcd_raw, "EPSG:4326", method = "near")

# Resample to ~150m for performance
# fact = 5 means every 5x5 block of 30m pixels becomes one 150m pixel
# fun = "modal" picks the most common class in each block
# NOTE: larger rasters require a tile server for smooth rendering in Leaflet
# (see Step 10c comment in app.R for details). For a workshop demo,
# coarser resolution is the simplest workaround.
nlcd_coarse <- aggregate(nlcd_wgs, fact = 5, fun = "modal")

# Crop to our exact bounding box
# Use terra::ext explicitly to avoid masking conflicts with other packages
nlcd_crop <- crop(nlcd_coarse, terra::ext(
  bbox["xmin"], bbox["xmax"], bbox["ymin"], bbox["ymax"]
))

names(nlcd_crop) <- "landcover"

cat(paste(
  "NLCD raster:",
  nrow(nlcd_crop), "x", ncol(nlcd_crop), "pixels at ~150m\n"
))

# Save as GeoTIFF with integer data type
writeRaster(nlcd_crop, "data/nlcd_baltimore.tif",
            overwrite = TRUE, datatype = "INT1U")
cat("Saved: data/nlcd_baltimore.tif\n\n")


# ==============================================================================
# SUMMARY
# ==============================================================================

cat("=============================================================\n")
cat("Data preparation complete. Files saved to data/:\n\n")

files <- c("data/wq_baltimore.csv",
           "data/watersheds_baltimore.gpkg",
           "data/nlcd_baltimore.tif")

for (f in files) {
  if (file.exists(f)) {
    size_kb <- round(file.size(f) / 1024)
    cat(paste0("  [OK] ", f, " (", size_kb, " KB)\n"))
  } else {
    cat(paste0("  [MISSING] ", f, "\n"))
  }
}

cat("\n--- Water quality summary ---\n")
wq_summary <- read_csv("data/wq_baltimore.csv", show_col_types = FALSE)
cat("Rows:", nrow(wq_summary), "\n")
cat("Stations:", n_distinct(wq_summary$station_id), "\n")
cat("Date range:", as.character(min(wq_summary$date)),
    "to", as.character(max(wq_summary$date)), "\n")
cat("Parameters:", paste(unique(wq_summary$parameter), collapse = ", "), "\n")
cat("Station names:\n")
for (s in unique(wq_summary$station_name)) cat(" ", s, "\n")

cat("\n--- Watershed summary ---\n")
ws_summary <- st_read("data/watersheds_baltimore.gpkg", quiet = TRUE)
cat("HUC8 units:", nrow(ws_summary), "\n")
for (i in seq_len(nrow(ws_summary))) {
  cat(" ", ws_summary$huc8[i], "-", ws_summary$huc8_name[i],
      "(", ws_summary$area_km2[i], "km2)\n")
}
cat("All geometries valid:", all(st_is_valid(ws_summary)), "\n")

cat("\n--- NLCD raster summary ---\n")
nlcd_summary <- rast("data/nlcd_baltimore.tif")
cat("Dimensions:", nrow(nlcd_summary), "x", ncol(nlcd_summary), "pixels\n")
cat("Resolution:", round(res(nlcd_summary)[1] * 111000), "m approx\n")
cat("Extent:", paste(round(as.vector(ext(nlcd_summary)), 3), collapse = ", "), "\n")
cat("Unique land cover classes:", length(unique(values(nlcd_summary, na.rm = TRUE))), "\n")

cat("\nNext steps:\n")
cat("  1. The real data is already active in app.R (Step 2 is uncommented)\n")
cat("  2. Click Run App in RStudio\n")
cat("  3. To revert to simulated data, set if (FALSE) to if (TRUE) in Step 3\n")
cat("=============================================================\n")
