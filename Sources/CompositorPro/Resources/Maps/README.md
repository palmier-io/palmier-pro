# Bundled map sources

All geography/relief assets here derive from Natural Earth, whose raster and vector data are public domain: https://www.naturalearthdata.com/about/terms-of-use/

- `atlas.json`: Natural Earth `ne_110m_admin_0_countries` and `ne_50m_admin_1_states_provinces`, from https://github.com/nvkelso/natural-earth-vector/tree/master/geojson. Country outlines are 1:110m; the 1:50m subdivision dataset provides 294 features, not every subdivision worldwide. The atlas stores original classifications, aliases, polygon holes and generalized editorial centers. Source URLs and a content version are in the JSON.
- `earth-relief.jpg`: Natural Earth I with shaded relief, land cover and water, 1:50m, from https://naturalearth.s3.amazonaws.com/50m_raster/NE1_50M_LC_SR_W.zip. The source TIFF is downsampled to 5400x2700 and JPEG encoded at quality 89. It is relief/cartographic imagery, not live satellite photography.

Regenerate the vector file with `python3 scripts/maps/prepare_atlas.py SOURCE_DIRECTORY Sources/CompositorPro/Resources/Maps/atlas.json`, where the source directory contains the two downloaded GeoJSON files as `countries.geojson` and `admin1.geojson`. Regenerate the raster with `python3 scripts/maps/prepare_relief.py SOURCE_ZIP Sources/CompositorPro/Resources/Maps/earth-relief.jpg` (Pillow required). Neither script accesses the network or writes to a live project package.

The dataset is illustrative and generalized. Resolve detailed geography and factual/copyright claims independently. Custom user images do not inherit Natural Earth's public-domain status.
