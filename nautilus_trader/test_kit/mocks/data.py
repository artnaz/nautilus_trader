# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2023 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

import tempfile

import pandas as pd

from nautilus_trader.backtest.data.wranglers import QuoteTickDataWrangler
from nautilus_trader.model.identifiers import Venue
from nautilus_trader.persistence.catalog.parquet import ParquetDataCatalog
from nautilus_trader.persistence.external.util import clear_singleton_instances
from nautilus_trader.trading.filters import NewsEvent


class NewsEventData(NewsEvent):
    """Generic data NewsEvent"""

    pass


def data_catalog_setup(protocol, path=tempfile.mktemp()) -> ParquetDataCatalog:
    if protocol not in ("memory", "file"):
        raise ValueError("`fs_protocol` should only be one of `memory` or `file` for testing")

    clear_singleton_instances(ParquetDataCatalog)

    catalog = ParquetDataCatalog(path)

    return catalog


def aud_usd_data_loader(catalog: ParquetDataCatalog):
    from nautilus_trader.backtest.data.providers import TestInstrumentProvider
    from tests.unit_tests.backtest.test_backtest_config import TEST_DATA_DIR

    venue = Venue("SIM")
    instrument = TestInstrumentProvider.default_fx_ccy("AUD/USD", venue=venue)
    catalog.write([instrument])
    wrangler = QuoteTickDataWrangler(instrument)
    df = pd.read_csv(f"{TEST_DATA_DIR}/truefx-audusd-ticks.csv")
    data = wrangler.process(df)
    catalog.write(data)
