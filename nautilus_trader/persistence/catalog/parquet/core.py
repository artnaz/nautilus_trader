from nautilus_trader.persistence.catalog.parquet.reader import ParquetDataCatalogReader
from nautilus_trader.persistence.catalog.parquet.writer import ParquetDataCatalogWriter


class ParquetDataCatalog(ParquetDataCatalogReader, ParquetDataCatalogWriter):
    """ParquetDataCatalog"""

    def __init__(self, catalog_url: str):
        ParquetDataCatalogReader.__init__(self, catalog_url)
        ParquetDataCatalogWriter.__init__(self, catalog_url)
