# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
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

"""
Defines various order types to be used for trading.
"""

from typing import Dict

from cpython.datetime cimport datetime

from nautilus_trader.core.constants cimport *  # str constants
from nautilus_trader.core.correctness cimport Condition
from nautilus_trader.core.datetime cimport format_iso8601
from nautilus_trader.core.decimal cimport Decimal
from nautilus_trader.core.uuid cimport UUID
from nautilus_trader.model.c_enums.liquidity_side cimport LiquiditySide
from nautilus_trader.model.c_enums.order_side cimport OrderSide
from nautilus_trader.model.c_enums.order_side cimport order_side_to_string
from nautilus_trader.model.c_enums.order_state cimport OrderState
from nautilus_trader.model.c_enums.order_state cimport order_state_to_string
from nautilus_trader.model.c_enums.order_type cimport OrderType
from nautilus_trader.model.c_enums.order_type cimport order_type_to_string
from nautilus_trader.model.c_enums.time_in_force cimport TimeInForce
from nautilus_trader.model.c_enums.time_in_force cimport time_in_force_to_string
from nautilus_trader.model.events cimport OrderAccepted
from nautilus_trader.model.events cimport OrderCancelled
from nautilus_trader.model.events cimport OrderDenied
from nautilus_trader.model.events cimport OrderEvent
from nautilus_trader.model.events cimport OrderExpired
from nautilus_trader.model.events cimport OrderFilled
from nautilus_trader.model.events cimport OrderInitialized
from nautilus_trader.model.events cimport OrderInvalid
from nautilus_trader.model.events cimport OrderModified
from nautilus_trader.model.events cimport OrderRejected
from nautilus_trader.model.events cimport OrderSubmitted
from nautilus_trader.model.events cimport OrderWorking
from nautilus_trader.model.identifiers cimport ClientOrderId
from nautilus_trader.model.identifiers cimport ExecutionId
from nautilus_trader.model.identifiers cimport Symbol
from nautilus_trader.model.objects cimport Price
from nautilus_trader.model.objects cimport Quantity
from nautilus_trader.model.parsing cimport convert_datetime_to_string
from nautilus_trader.model.parsing cimport convert_string_to_datetime
from nautilus_trader.model.parsing cimport convert_string_to_price


# States which represent a 'completed' order
cdef set _COMPLETED_STATES = {
    OrderState.INVALID,
    OrderState.DENIED,
    OrderState.REJECTED,
    OrderState.CANCELLED,
    OrderState.EXPIRED,
    OrderState.FILLED,
}


# State being used as trigger
cdef dict _ORDER_STATE_TABLE = {
    (OrderState.INITIALIZED, OrderState.CANCELLED): OrderState.CANCELLED,
    (OrderState.INITIALIZED, OrderState.INVALID): OrderState.INVALID,
    (OrderState.INITIALIZED, OrderState.DENIED): OrderState.DENIED,
    (OrderState.INITIALIZED, OrderState.SUBMITTED): OrderState.SUBMITTED,
    (OrderState.SUBMITTED, OrderState.CANCELLED): OrderState.CANCELLED,
    (OrderState.SUBMITTED, OrderState.REJECTED): OrderState.REJECTED,
    (OrderState.SUBMITTED, OrderState.ACCEPTED): OrderState.ACCEPTED,
    (OrderState.SUBMITTED, OrderState.WORKING): OrderState.WORKING,
    (OrderState.REJECTED, OrderState.REJECTED): OrderState.REJECTED,
    (OrderState.ACCEPTED, OrderState.CANCELLED): OrderState.CANCELLED,
    (OrderState.ACCEPTED, OrderState.WORKING): OrderState.WORKING,
    (OrderState.ACCEPTED, OrderState.PARTIALLY_FILLED): OrderState.PARTIALLY_FILLED,
    (OrderState.ACCEPTED, OrderState.FILLED): OrderState.FILLED,
    (OrderState.WORKING, OrderState.CANCELLED): OrderState.CANCELLED,
    (OrderState.WORKING, OrderState.WORKING): OrderState.WORKING,
    (OrderState.WORKING, OrderState.EXPIRED): OrderState.EXPIRED,
    (OrderState.WORKING, OrderState.PARTIALLY_FILLED): OrderState.PARTIALLY_FILLED,
    (OrderState.WORKING, OrderState.FILLED): OrderState.FILLED,
    (OrderState.PARTIALLY_FILLED, OrderState.CANCELLED): OrderState.FILLED,
    (OrderState.PARTIALLY_FILLED, OrderState.PARTIALLY_FILLED): OrderState.PARTIALLY_FILLED,
    (OrderState.PARTIALLY_FILLED, OrderState.FILLED): OrderState.FILLED,
}


# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class Order:
    """
    The base class for all orders.
    """

    def __init__(self, OrderInitialized event not None):
        """
        Initialize a new instance of the Order class.

        Parameters
        ----------
        event : OrderInitialized
            The order initialized event.

        """
        self._execution_ids = []  # type: [ExecutionId]
        self._events = []         # type: [OrderEvent]
        self._fsm = FiniteStateMachine(
            state_transition_table=_ORDER_STATE_TABLE,
            initial_state=OrderState.INITIALIZED,
            trigger_parser=order_state_to_string,  # order_state_to_string correct here
            state_parser=order_state_to_string,
        )

        self._cl_ord_id = event.cl_ord_id
        self._strategy_id = event.strategy_id
        self._id = None                # Can be None (OrderId from broker/exchange)
        self._position_id = None       # Can be None
        self._account_id = None        # Can be None
        self._execution_id = None      # Can be None
        self._symbol = event.symbol
        self._side = event.order_side
        self._type = event.order_type
        self._quantity = event.quantity
        self._timestamp = event.timestamp
        self._time_in_force = event.time_in_force
        self._filled_qty = Quantity()
        self._filled_timestamp = None  # Can be None
        self._avg_price = None         # Can be None
        self._slippage = Decimal()
        self._init_id = event.id

        self._events.append(event)

    def __eq__(self, Order other) -> bool:
        return self._cl_ord_id == other.cl_ord_id

    def __ne__(self, Order other) -> bool:
        return self._cl_ord_id != other.cl_ord_id

    def __hash__(self) -> int:
        return hash(self._cl_ord_id.value)

    def __repr__(self) -> str:
        cdef str id_string = f"id={self.id.value}, " if self.id else ""
        return (f"{type(self).__name__}("
                f"cl_ord_id={self._cl_ord_id.value}, "
                f"{id_string}"
                f"state={self._fsm.state_string()}, "
                f"{self.status_string()})")

    @property
    def cl_ord_id(self):
        """
        The orders client order identifier.

        Returns
        -------
        ClientOrderId

        """
        return self._cl_ord_id

    @property
    def strategy_id(self):
        """
        The strategy identifier associated with the order.

        Returns
        -------
        StrategyId

        """
        return self._strategy_id

    @property
    def id(self):
        """
        The order identifier.

        This can be assigned by the exchange/broker, or be system generated.

        Returns
        -------
        OrderId or None

        """
        return self._id

    @property
    def account_id(self):
        """
        The account identifier associated with the order.

        Returns
        -------
        AccountId or None

        """
        return self._account_id

    @property
    def execution_id(self):
        """
        The orders last execution identifier.

        Returns
        -------
        ExecutionId or None

        """
        return self._execution_id

    @property
    def position_id(self):
        """
        The position identifier associated with the order.

        Returns
        -------
        PositionId or None

        """
        return self._position_id

    @property
    def symbol(self):
        """
        The order symbol.

        Returns
        -------
        Symbol

        """
        return self._symbol

    @property
    def side(self):
        """
        The order side.

        Returns
        -------
        OrderSide

        """
        return self._side

    @property
    def type(self):
        """
        The order type.

        Returns
        -------
        OrderType

        """
        return self._type

    @property
    def quantity(self):
        """
        The order quantity.

        Returns
        -------
        Quantity

        """
        return self._quantity

    @property
    def timestamp(self):
        """
        The order initialization timestamp.

        Returns
        -------
        datetime

        """
        return self._timestamp

    @property
    def time_in_force(self):
        """
        The order time-in-force.

        Returns
        -------
        TimeInForce

        """
        return self._time_in_force

    @property
    def filled_qty(self):
        """
        The order total filled quantity.

        Returns
        -------
        Quantity

        """
        return self._filled_qty

    @property
    def filled_timestamp(self):
        """
        The order last filled timestamp.

        Returns
        -------
        datetime or None

        """
        return self._filled_timestamp

    @property
    def avg_price(self):
        """
        The order average fill price.

        Returns
        -------
        Decimal or None

        """
        return self._avg_price

    @property
    def slippage(self):
        """
        The order total price slippage.

        Returns
        -------
        Decimal

        """
        return self._slippage

    @property
    def init_id(self):
        """
        The identifier of the `OrderInitialized` event.

        Returns
        -------
        UUID

        """
        return self._init_id

    @property
    def state(self):
        """
        The orders current state.

        Returns
        -------
        OrderState

        """
        return self._fsm.state

    @property
    def last_event(self):
        """
        The last event applied to the order.

        Returns
        -------
        OrderEvent

        """
        return self._events[-1]

    @property
    def execution_ids(self):
        """
        The execution identifiers.

        Returns
        -------
        list[ExecutionId]

        """
        return self._execution_ids.copy()

    @property
    def events(self):
        """
        The order events.

        Returns
        -------
        list[OrderEvent]

        """
        return self._events.copy()

    @property
    def event_count(self):
        """
        The count of events applied to the order.

        Returns
        -------
        int

        """
        return len(self._events)

    @property
    def is_buy(self):
        """
        If the order side is `BUY`.

        Returns
        -------
        bool
            True if BUY, else False.

        """
        return self._side == OrderSide.BUY

    @property
    def is_sell(self):
        """
        If the order side is `SELL`.

        Returns
        -------
        bool
            True if SELL, else False.

        """
        return self._side == OrderSide.SELL

    @property
    def is_working(self):
        """
        If the order is `WORKING`.

        Returns
        -------
        bool
            True if WORKING, else False.

        """
        return self._fsm.state == OrderState.WORKING

    @property
    def is_completed(self):
        """
        If the order is `completed`.

        Returns
        -------
        bool
            True if completed, else False.

        """
        return self._fsm.state in _COMPLETED_STATES

    @staticmethod
    cdef OrderSide opposite_side_c(OrderSide side) except *:
        """
        Return the opposite order side from the given side.

        Parameters
        ----------
        side : OrderSide
            The original order side.

        Returns
        -------
        OrderSide

        Raises
        ------
        ValueError
            If side is UNDEFINED.

        """
        Condition.not_equal(side, OrderSide.UNDEFINED, "side", "OrderSide.UNDEFINED")

        return OrderSide.BUY if side == OrderSide.SELL else OrderSide.SELL

    @staticmethod
    def opposite_side(OrderSide side) -> OrderSide:
        """
        Return the opposite order side from the given side.

        Parameters
        ----------
        side : OrderSide
            The original order side.

        Returns
        -------
        OrderSide

        """
        return Order.opposite_side_c(side)

    @staticmethod
    cdef inline OrderSide flatten_side_c(PositionSide side) except *:
        """
        Return the order side needed to flatten a position from the given side.

        Parameters
        ----------
        side : PositionSide
            The position side to flatten.

        Returns
        -------
        OrderSide

        Raises
        ------
        ValueError
            If side is UNDEFINED or FLAT.

        """
        Condition.not_equal(side, PositionSide.UNDEFINED, "side", "PositionSide.UNDEFINED")
        Condition.not_equal(side, PositionSide.FLAT, "side", "PositionSide.FLAT")

        return OrderSide.BUY if side == PositionSide.SHORT else OrderSide.SELL

    @staticmethod
    def flatten_side(PositionSide side) -> OrderSide:
        """
        Return the order side needed to flatten a position from the given side.

        Parameters
        ----------
        side : PositionSide
            The position side to flatten.

        Returns
        -------
        OrderSide

        Raises
        ------
        ValueError
            If side is UNDEFINED or FLAT.

        """
        return Order.flatten_side_c(side)

    cdef str state_string(self):
        """
        The orders state as a string.

        Returns
        -------
        str

        """
        return self._fsm.state_string()

    cdef str status_string(self):
        """
        The orders status as a string.

        Returns
        -------
        str

        """
        raise NotImplemented("method must be implemented in subclass")

    cpdef void apply(self, OrderEvent event) except *:
        """
        Apply the given order event to the order.

        Parameters
        ----------
        event : OrderEvent
            The order event to apply.

        Raises
        ------
        ValueError
            If event.cl_ord_id is not equal to the orders cl_ord_id.
        ValueError
            If event.account_id is not equal to the orders account_id.
        InvalidStateTrigger
            If event is not a valid trigger from the current order.state.

        """
        Condition.not_none(event, "event")
        Condition.equal(self._cl_ord_id, event.cl_ord_id, "id", "event.order_id")

        # Update events
        self._events.append(event)

        # Handle event - FSM (raises InvalidStateTrigger if trigger invalid)
        if isinstance(event, OrderInvalid):
            self._fsm.trigger(OrderState.INVALID)
            self._invalid(event)
        elif isinstance(event, OrderDenied):
            self._fsm.trigger(OrderState.DENIED)
            self._denied(event)
        elif isinstance(event, OrderSubmitted):
            self._fsm.trigger(OrderState.SUBMITTED)
            self._submitted(event)
        elif isinstance(event, OrderRejected):
            self._fsm.trigger(OrderState.REJECTED)
            self._rejected(event)
        elif isinstance(event, OrderAccepted):
            self._fsm.trigger(OrderState.ACCEPTED)
            self._accepted(event)
        elif isinstance(event, OrderWorking):
            self._fsm.trigger(OrderState.WORKING)
            self._working(event)
        elif isinstance(event, OrderCancelled):
            self._fsm.trigger(OrderState.CANCELLED)
            self._cancelled(event)
        elif isinstance(event, OrderExpired):
            self._fsm.trigger(OrderState.EXPIRED)
            self._expired(event)
        elif isinstance(event, OrderModified):
            self._fsm.trigger(OrderState.WORKING)
            self._modified(event)
        elif isinstance(event, OrderFilled):
            if event.is_partial_fill:
                self._fsm.trigger(OrderState.PARTIALLY_FILLED)
                self._filled(event)
            else:
                self._fsm.trigger(OrderState.FILLED)
                self._filled(event)

    cdef void _invalid(self, OrderInvalid event) except *:
        pass  # Do nothing else

    cdef void _denied(self, OrderDenied event) except *:
        pass  # Do nothing else

    cdef void _submitted(self, OrderSubmitted event) except *:
        self._account_id = event.account_id

    cdef void _rejected(self, OrderRejected event) except *:
        pass  # Do nothing else

    cdef void _accepted(self, OrderAccepted event) except *:
        self._id = event.order_id

    cdef void _working(self, OrderWorking event) except *:
        pass  # Do nothing else

    cdef void _cancelled(self, OrderCancelled event) except *:
        pass  # Do nothing else

    cdef void _expired(self, OrderExpired event) except *:
        pass  # Do nothing else

    cdef void _modified(self, OrderModified event) except *:
        # Abstract method
        raise NotImplemented("method must be implemented in subclass")

    cdef void _filled(self, OrderFilled event) except *:
        # Abstract method
        raise NotImplemented("method must be implemented in subclass")


# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class PassiveOrder(Order):
    """
    The base class for all passive orders.
    """
    def __init__(
            self,
            ClientOrderId cl_ord_id not None,
            StrategyId strategy_id not None,
            Symbol symbol not None,
            OrderSide order_side,
            OrderType order_type,  # 'type' hides keyword
            Quantity quantity not None,
            Price price not None,
            TimeInForce time_in_force,
            datetime expire_time,  # Can be None
            UUID init_id not None,
            datetime timestamp not None,
            dict options not None: Dict[str, str],
    ):
        """
        Initialize a new instance of the PassiveOrder class.

        Parameters
        ----------
        cl_ord_id : ClientOrderId
            The client order identifier.
        strategy_id : StrategyId
            The order strategy identifier.
        symbol : Symbol
            The order symbol.
        order_side : OrderSide (enum)
            The order side (BUY or SELL).
        order_type : OrderType (enum)
            The order type.
        quantity : Quantity
            The order quantity (> 0).
        price : Price
            The order price.
        time_in_force : TimeInForce
            The order time-in-force.
        expire_time : datetime, optional
            The order expiry time - for GTD orders only.
        init_id : UUID
            The order initialization event identifier.
        timestamp : datetime
            The order initialization timestamp.
        options : dict
            The order options.

        Raises
        ------
        ValueError
            If quantity is not positive (> 0).
        ValueError
            If order_side is UNDEFINED.
        ValueError
            If order_type is UNDEFINED.
        ValueError
            If time_in_force is UNDEFINED.
        ValueError
            If time_in_force is GTD and the expire_time is None.

        """
        Condition.positive(quantity, "quantity")
        Condition.not_equal(time_in_force, TimeInForce.UNDEFINED, "time_in_force", "UNDEFINED")
        if time_in_force == TimeInForce.GTD:
            # Must have an expire time
            Condition.not_none(expire_time, "expire_time")
        else:
            # Should not have an expire time
            Condition.none(expire_time, "expire_time")

        options[PRICE] = str(price)  # price should never be None
        options[EXPIRE_TIME] = convert_datetime_to_string(expire_time)

        cdef OrderInitialized init_event = OrderInitialized(
            cl_ord_id=cl_ord_id,
            strategy_id=strategy_id,
            symbol=symbol,
            order_side=order_side,
            order_type=order_type,
            quantity=quantity,
            time_in_force=time_in_force,
            event_id=init_id,
            event_timestamp=timestamp,
            options=options,
        )
        super().__init__(init_event)

        self._price = price
        self._liquidity_side = LiquiditySide.NONE
        self._expire_time = expire_time
        self._slippage = Decimal()

    @property
    def price(self):
        """
        The order price.

        Returns
        -------
        Price

        """
        return self._price

    @property
    def liquidity_side(self):
        """
        The order liquidity size.

        Returns
        -------
        LiquiditySide

        """
        return self._liquidity_side

    @property
    def expire_time(self):
        """
        The order expire time (optional).

        Returns
        -------
        datetime or None

        """
        return self._expire_time

    cdef str status_string(self):
        """
        Return the orders status as a string.

        Returns
        -------
        str

        """
        cdef str expire_time = "" if self.expire_time is None else f" {format_iso8601(self._expire_time)}"
        return (f"{order_side_to_string(self._side)} {self._quantity.to_string()} {self._symbol} "
                f"{order_type_to_string(self._type)} @ {self._price} "
                f"{time_in_force_to_string(self._time_in_force)}{expire_time}")

    cdef void _modified(self, OrderModified event) except *:
        self._id = event.order_id
        self._quantity = event.modified_quantity
        self._price = event.modified_price

    cdef void _filled(self, OrderFilled event) except *:
        self._id = event.order_id
        self._position_id = event.position_id
        self._strategy_id = event.strategy_id
        self._execution_ids.append(event.execution_id)
        self._execution_id = event.execution_id
        self._liquidity_side = event.liquidity_side
        self._filled_qty = event.filled_qty
        self._filled_timestamp = event.timestamp
        self._avg_price = event.avg_price
        self._set_slippage()

    cdef void _set_slippage(self) except *:

        cdef Decimal price
        if self.side == OrderSide.BUY:
            self._slippage = Decimal(self._avg_price - self._price)
        else:  # self.side == OrderSide.SELL:
            self._slippage = Decimal(self._price - self._avg_price)


cdef set _MARKET_ORDER_VALID_TIF = {
    TimeInForce.DAY,
    TimeInForce.IOC,
    TimeInForce.FOC,
}

# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class MarketOrder(Order):
    """
    A market order is an order to buy or sell an instrument immediately. This
    type of order guarantees that the order will be executed, but does not
    guarantee the execution price. A market order generally will execute at or
    near the current bid (for a sell order) or ask (for a buy order) price. The
    last-traded price is not necessarily the price at which a market order will
    be executed.
    """
    def __init__(
            self,
            ClientOrderId cl_ord_id not None,
            StrategyId strategy_id not None,
            Symbol symbol not None,
            OrderSide order_side,
            Quantity quantity not None,
            TimeInForce time_in_force,
            UUID init_id not None,
            datetime timestamp not None,
    ):
        """
        Initialize a new instance of the MarketOrder class.

        Parameters
        ----------
        cl_ord_id : ClientOrderId
            The client order identifier.
        strategy_id : StrategyId
            The order strategy identifier.
        symbol : Symbol
            The order symbol.
        order_side : OrderSide (enum)
            The order side (BUY or SELL).
        quantity : Quantity
            The order quantity (> 0).
        init_id : UUID
            The order initialization event identifier.
        timestamp : datetime
            The order initialization timestamp.

        Raises
        ------
        ValueError
            If quantity is not positive (> 0).
        ValueError
            If order_side is UNDEFINED.
        ValueError
            If time_in_force is UNDEFINED.
        ValueError
            If time_in_force is other than DAY, IOC or FOC.

        """
        Condition.positive(quantity, "quantity")
        Condition.true(time_in_force in _MARKET_ORDER_VALID_TIF, "time_in_force is DAY, IOC or FOC")

        cdef OrderInitialized init_event = OrderInitialized(
            cl_ord_id=cl_ord_id,
            strategy_id=strategy_id,
            symbol=symbol,
            order_side=order_side,
            order_type=OrderType.MARKET,
            quantity=quantity,
            time_in_force=time_in_force,
            event_id=init_id,
            event_timestamp=timestamp,
            options={},
        )

        super().__init__(init_event)

    @staticmethod
    cdef MarketOrder create(OrderInitialized event):
        """
        Return an order from the given initialized event.

        Parameters
        ----------
        event : OrderInitialized
            The event to initialize with.

        Returns
        -------
        Order

        """
        Condition.not_none(event, "event")

        return MarketOrder(
            cl_ord_id=event.cl_ord_id,
            strategy_id=event.strategy_id,
            symbol=event.symbol,
            order_side=event.order_side,
            quantity=event.quantity,
            time_in_force=event.time_in_force,
            init_id=event.id,
            timestamp=event.timestamp,
        )

    cdef str status_string(self):
        """
        Return the orders status as a string.

        Returns
        -------
        str

        """
        return (f"{order_side_to_string(self._side)} {self._quantity.to_string()} {self._symbol} "
                f"{order_type_to_string(self._type)} "
                f"{time_in_force_to_string(self._time_in_force)}")

    cdef void _modified(self, OrderModified event) except *:
        raise NotImplemented("Cannot modify a market order")

    cdef void _filled(self, OrderFilled event) except *:
        self._id = event.order_id
        self._position_id = event.position_id
        self._strategy_id = event.strategy_id
        self._execution_ids.append(event.execution_id)
        self._execution_id = event.execution_id
        self._filled_qty = event.filled_qty
        self._filled_timestamp = event.timestamp
        self._avg_price = event.avg_price


# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class LimitOrder(PassiveOrder):
    """
    Limit orders are used to specify a maximum or minimum price the trader is
    willing to buy or sell at. Traders use this order type to minimise their
    trading cost, however they are sacrificing guaranteed execution as there is
    a chance the order may not be executed if it is placed deep out of the
    market.
    """
    def __init__(
            self,
            ClientOrderId cl_ord_id not None,
            StrategyId strategy_id not None,
            Symbol symbol not None,
            OrderSide order_side,
            Quantity quantity not None,
            Price price not None,
            TimeInForce time_in_force,
            datetime expire_time,  # Can be None
            UUID init_id not None,
            datetime timestamp not None,
            bint post_only=True,
            bint hidden=False,
    ):
        """
        Initialize a new instance of the LimitOrder class.

        Parameters
        ----------
        cl_ord_id : ClientOrderId
            The client order identifier.
        strategy_id : StrategyId
            The order strategy identifier.
        symbol : Symbol
            The order symbol.
        order_side : OrderSide (enum)
            The order side (BUY or SELL).
        quantity : Quantity
            The order quantity (> 0).
        price : Price
            The order limit price.
        time_in_force : TimeInForce
            The order time-in-force.
        expire_time : datetime, optional
            The order expiry time.
        init_id : UUID
            The order initialization event identifier.
        timestamp : datetime
            The order initialization timestamp.
        post_only : bool, optional;
            If the order will only make a market.
        hidden : bool, optional
            If the order should be hidden from the public book.

        Raises
        ------
        ValueError
            If quantity is not positive (> 0).
        ValueError
            If order_side is UNDEFINED.
        ValueError
            If time_in_force is UNDEFINED.
        ValueError
            If time_in_force is GTD and expire_time is None.

        """
        self._is_post_only = post_only
        self._is_hidden = hidden

        cdef dict options = {
            POST_ONLY: post_only,
            HIDDEN: hidden,
        }

        super().__init__(
            cl_ord_id,
            strategy_id,
            symbol,
            order_side,
            OrderType.LIMIT,
            quantity,
            price,
            time_in_force,
            expire_time,
            init_id,
            timestamp,
            options,
        )

    @staticmethod
    cdef LimitOrder create(OrderInitialized event):
        """
        Return a limit order from the given initialized event.

        Parameters
        ----------
        event : OrderInitialized
            The event to initialize with.

        Returns
        -------
        Order

        """
        Condition.not_none(event, "event")

        return LimitOrder(
            cl_ord_id=event.cl_ord_id,
            symbol=event.symbol,
            order_side=event.order_side,
            quantity=event.quantity,
            price=convert_string_to_price(event.options.get(PRICE)),
            time_in_force=event.time_in_force,
            expire_time=convert_string_to_datetime(event.options[EXPIRE_TIME]),
            init_id=event.id,
            timestamp=event.timestamp,
            post_only=event.options.get(POST_ONLY),
            hidden=event.options.get(HIDDEN),
        )

    @property
    def is_post_only(self):
        """
        If the order is `post_only`, meaning it will only make liquidity.

        Returns
        -------
        bool
            True if post only, else False.

        """
        return self._is_post_only

    @property
    def is_hidden(self):
        """
        If the order is displayed on the public order book.

        Returns
        -------
        bool
            True if hidden, else False.

        """
        return self._is_hidden


# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class StopMarketOrder(PassiveOrder):
    """
    Represents a stop market order. Once the price crosses the predefined
    trigger price, the stop order becomes a market order.
    """
    def __init__(
            self,
            ClientOrderId cl_ord_id not None,
            StrategyId strategy_id not None,
            Symbol symbol not None,
            OrderSide order_side,
            Quantity quantity not None,
            Price price not None,
            TimeInForce time_in_force,
            datetime expire_time,  # Can be None
            UUID init_id not None,
            datetime timestamp not None,
    ):
        """
        Initialize a new instance of the StopMarketOrder class.

        Parameters
        ----------
        cl_ord_id : ClientOrderId
            The client order identifier.
        strategy_id : StrategyId
            The order strategy identifier.
        symbol : Symbol
            The order symbol.
        order_side : OrderSide (enum)
            The order side (BUY or SELL).
        quantity : Quantity
            The order quantity (> 0).
        price : Price
            The order stop price.
        time_in_force : TimeInForce
            The order time-in-force.
        expire_time : datetime, optional
            The order expiry time.
        init_id : UUID
            The order initialization event identifier.
        timestamp : datetime
            The order initialization timestamp.

        Raises
        ------
        ValueError
            If quantity is not positive (> 0).
        ValueError
            If order_side is UNDEFINED.
        ValueError
            If time_in_force is UNDEFINED.
        ValueError
            If time_in_force is GTD and the expire_time is None.

        """
        super().__init__(
            cl_ord_id,
            strategy_id,
            symbol,
            order_side,
            OrderType.STOP_MARKET,
            quantity,
            price,
            time_in_force,
            expire_time,
            init_id,
            timestamp,
            options={},
        )

    @staticmethod
    cdef StopMarketOrder create(OrderInitialized event):
        """
        Return a stop order from the given initialized event.

        Parameters
        ----------
        event : OrderInitialized
            The event to initialize with.

        Returns
        -------
        Order

        """
        Condition.not_none(event, "event")

        return StopMarketOrder(
            cl_ord_id=event.cl_ord_id,
            strategy_id=event.strategy_id,
            symbol=event.symbol,
            order_side=event.order_side,
            quantity=event.quantity,
            price=convert_string_to_price(event.options.get(PRICE)),
            time_in_force=event.time_in_force,
            expire_time=convert_string_to_datetime(event.options[EXPIRE_TIME]),
            init_id=event.id,
            timestamp=event.timestamp,
        )


# noinspection: Object has warned attribute
# noinspection PyUnresolvedReferences
cdef class BracketOrder:
    """
    A bracket orders is designed to help limit a traders loss and optionally
    lock in a profit by "bracketing" an entry order with two opposite-side exit
    orders. A BUY order is bracketed by a high-side sell limit order and a
    low-side sell stop order. A SELL order is bracketed by a high-side buy stop
    order and a low side buy limit order.
    Once the 'parent' entry order is triggered the 'child' OCO orders being a
    STOP and optional LIMIT automatically become working on the exchange/broker side.
    """
    def __init__(
            self,
            Order entry not None,
            StopMarketOrder stop_loss not None,
            LimitOrder take_profit=None,
    ):
        """
        Initialize a new instance of the BracketOrder class.

        Parameters
        ----------
        entry : Order
            The entry 'parent' order.
        stop_loss : StopMarketOrder
            The stop-loss (SL) 'child' order.
        take_profit : LimitOrder, optional
            The take-profit (TP) 'child' order.

        """
        self._id = BracketOrderId(f"B{entry.cl_ord_id.value}")
        self._entry = entry
        self._stop_loss = stop_loss
        self._take_profit = take_profit
        self._timestamp = entry.timestamp

    def __eq__(self, BracketOrder other) -> bool:
        return self.id == other.id

    def __ne__(self, BracketOrder other) -> bool:
        return self.id != other.id

    def __hash__(self) -> int:
        return hash(self.id)

    def __repr__(self) -> str:
        cdef str take_profit_price = "NONE" if self._take_profit is None else str(self._take_profit.price)
        return f"BracketOrder(id={self._id.value}, Entry{self._entry}, SL={self._stop_loss.price}, TP={take_profit_price})"

    @property
    def id(self):
        """
        The bracket order identifier.

        Returns
        -------
        BracketOrderId

        """
        return self._id

    @property
    def entry(self):
        """
        The entry order.

        Returns
        -------
        Order

        """
        return self._entry

    @property
    def stop_loss(self):
        """
        The stop-loss order.

        Returns
        -------
        StopMarketOrder

        """
        return self._stop_loss

    @property
    def take_profit(self):
        """
        The take-profit order (optional).

        Returns
        -------
        PassiveOrder or None

        """
        return self._take_profit

    @property
    def has_take_profit(self):
        """
        If the bracket order has a take-profit

        Returns
        -------
        bool
            True if has take-profit, else False.

        """
        return self._take_profit is not None

    @property
    def timestamp(self):
        """
        The bracket order initialization timestamp.

        Returns
        -------
        datetime

        """
        return self._timestamp
