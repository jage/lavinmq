# AMQP 0-9-1 Reference

> Generated from the specification XML, in the edition RabbitMQ publishes,
> <https://www.rabbitmq.com/resources/specs/amqp0-9-1.extended.xml>. It adds
> RabbitMQ's extensions to the official specification, which are marked
> "RabbitMQ extension" below. The general specification is in
> `amqp0-9-1.md`.

AMQP 0-9-1, default port 5672.

## Copyright and license

```text
Copyright Notice
================
Copyright (c) 2006-2008 Cisco Systems, Credit Suisse, Deutsche Boerse
Systems, Envoy Technologies, Inc., Goldman Sachs, IONA Technologies PLC,
iMatix Corporation, JPMorgan Chase Bank Inc. N.A, Novell, Rabbit
Technologies Ltd., Red Hat, Inc., TWIST Process Innovations Ltd, WS02
Inc. and 29West Inc. All rights reserved.

License
=======
Cisco Systems, Credit Suisse, Deutsche Boerse Systems, Envoy Technologies,
Inc., Goldman Sachs, IONA Technologies PLC, iMatix Corporation, JPMorgan
Chase Bank Inc. N.A, Novell, Rabbit Technologies Ltd., Red Hat, Inc.,
TWIST Process Innovations Ltd, WS02, Inc. and 29West Inc. (collectively,
the "Authors") each hereby grants to you a worldwide, perpetual,
royalty-free, nontransferable, nonexclusive license to (i) copy, display,
distribute and implement the Advanced Messaging Queue Protocol ("AMQP")
Specification and (ii) the Licensed Claims that are held by the Authors,
all for the purpose of implementing the Advanced Messaging Queue Protocol
Specification. Your license and any rights under this Agreement will
terminate immediately without notice from any Author if you bring any
claim, suit, demand, or action related to the Advanced Messaging Queue
Protocol Specification against any Author. Upon termination, you shall
destroy all copies of the Advanced Messaging Queue Protocol Specification
in your possession or control.

As used hereunder, "Licensed Claims" means those claims of a patent or
patent application, throughout the world, excluding design patents and
design registrations, owned or controlled, or that can be sublicensed
without fee and in compliance with the requirements of this Agreement,
by an Author or its affiliates now or at any future time and which would
necessarily be infringed by implementation of the Advanced Messaging
Queue Protocol Specification. A claim is necessarily infringed hereunder
only when it is not possible to avoid infringing it because there is no
plausible non-infringing alternative for implementing the required
portions of the Advanced Messaging Queue Protocol Specification.
Notwithstanding the foregoing, Licensed Claims shall not include any
claims other than as set forth above even if contained in the same patent
as Licensed Claims; or that read solely on any implementations of any
portion of the Advanced Messaging Queue Protocol Specification that are
not required by the Advanced Messaging Queue ProtocolSpecification, or
that, if licensed, would require a payment of royalties by the licensor
to unaffiliated third parties. Moreover, Licensed Claims shall not
include (i) any enabling technologies that may be necessary to make or
use any Licensed Product but are not themselves expressly set forth in
the Advanced Messaging Queue Protocol Specification (e.g., semiconductor
manufacturing technology, compiler technology, object oriented
technology, networking technology, operating system technology, and the
like); or (ii) the implementation of other published standards developed
elsewhere and merely referred to in the body of the Advanced Messaging
Queue Protocol Specification, or (iii) any Licensed Product and any
combinations thereof the purpose or function of which is not required
for compliance with the Advanced Messaging Queue Protocol Specification.
For purposes of this definition, the Advanced Messaging Queue Protocol
Specification shall be deemed to include both architectural and
interconnection requirements essential for interoperability and may also
include supporting source code artifacts where such architectural,
interconnection requirements and source code artifacts are expressly
identified as being required or documentation to achieve compliance with
the Advanced Messaging Queue Protocol Specification.

As used hereunder, "Licensed Products" means only those specific portions
of products (hardware, software or combinations thereof) that implement
and are compliant with all relevant portions of the Advanced Messaging
Queue Protocol Specification.

The following disclaimers, which you hereby also acknowledge as to any
use you may make of the Advanced Messaging Queue Protocol Specification:

THE ADVANCED MESSAGING QUEUE PROTOCOL SPECIFICATION IS PROVIDED "AS IS,"
AND THE AUTHORS MAKE NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
IMPLIED, INCLUDING, BUT NOT LIMITED TO, WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, OR TITLE; THAT THE
CONTENTS OF THE ADVANCED MESSAGING QUEUE PROTOCOL SPECIFICATION ARE
SUITABLE FOR ANY PURPOSE; NOR THAT THE IMPLEMENTATION OF THE ADVANCED
MESSAGING QUEUE PROTOCOL SPECIFICATION WILL NOT INFRINGE ANY THIRD PARTY
PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

THE AUTHORS WILL NOT BE LIABLE FOR ANY DIRECT, INDIRECT, SPECIAL,
INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF OR RELATING TO ANY
USE, IMPLEMENTATION OR DISTRIBUTION OF THE ADVANCED MESSAGING QUEUE
PROTOCOL SPECIFICATION.

The name and trademarks of the Authors may NOT be used in any manner,
including advertising or publicity pertaining to the Advanced Messaging
Queue Protocol Specification or its contents without specific, written
prior permission. Title to copyright in the Advanced Messaging Queue
Protocol Specification will at all times remain with the Authors.

No other rights are granted by implication, estoppel or otherwise.

Upon termination of your license or rights under this Agreement, you
shall destroy all copies of the Advanced Messaging Queue Protocol
Specification in your possession or control.

Trademarks
==========
JPMorgan, JPMorgan Chase, Chase, the JPMorgan Chase logo and the
Octagon Symbol are trademarks of JPMorgan Chase & Co.

IMATIX and the iMatix logo are trademarks of iMatix Corporation sprl.

IONA, IONA Technologies, and the IONA logos are trademarks of IONA
Technologies PLC and/or its subsidiaries.

LINUX is a trademark of Linus Torvalds. RED HAT and JBOSS are registered
trademarks of Red Hat, Inc. in the US and other countries.

Java, all Java-based trademarks and OpenOffice.org are trademarks of
Sun Microsystems, Inc. in the United States, other countries, or both.

Other company, product, or service names may be trademarks or service
marks of others.

Links to full AMQP specification:
=================================
http://www.amqp.org
```

The XML's note on RabbitMQ's modifications:

```text
WARNING: Modified from the official 0-9-1 specification XML by
the addition of:
confirm.select and confirm.select-ok,
exchange.bind and exchange.bind-ok,
exchange.unbind and exchange.unbind-ok,
basic.nack,
the ability for the Server to send basic.ack, basic.nack and
 basic.cancel to the client, and
the un-deprecation of exchange.declare{auto-delete} and exchange.declare{internal}

Modifications are (c) 2007-210 Broadcom. All Rights Reserved. The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
The modifications may be distributed under
the same BSD license as the stripped spec.
```

## Constants

| Name | Value | Class | Description |
|----|----|----|----|
| frame-method | 1 |  |  |
| frame-header | 2 |  |  |
| frame-body | 3 |  |  |
| frame-heartbeat | 8 |  |  |
| frame-min-size | 4096 |  |  |
| frame-end | 206 |  |  |
| reply-success | 200 |  | Indicates that the method completed successfully. This reply code is reserved for future use - the current protocol design does not use positive confirmation and reply codes are sent only in case of an error. |
| content-too-large | 311 | soft-error | The client attempted to transfer content larger than the server could accept at the present time. The client may retry at a later time. |
| no-route | 312 | soft-error | Returned when RabbitMQ sends back with 'basic.return' when a 'mandatory' message cannot be delivered to any queue. |
| no-consumers | 313 | soft-error | When the exchange cannot deliver to a consumer when the immediate flag is set. As a result of pending data on the queue or the absence of any consumers of the queue. |
| connection-forced | 320 | hard-error | An operator intervened to close the connection for some reason. The client may retry at some later date. |
| invalid-path | 402 | hard-error | The client tried to work with an unknown virtual host. |
| access-refused | 403 | soft-error | The client attempted to work with a server entity to which it has no access due to security settings. |
| not-found | 404 | soft-error | The client attempted to work with a server entity that does not exist. |
| resource-locked | 405 | soft-error | The client attempted to work with a server entity to which it has no access because another client is working with it. |
| precondition-failed | 406 | soft-error | The client requested a method that was not allowed because some precondition failed. |
| frame-error | 501 | hard-error | The sender sent a malformed frame that the recipient could not decode. This strongly implies a programming error in the sending peer. |
| syntax-error | 502 | hard-error | The sender sent a frame that contained illegal values for one or more fields. This strongly implies a programming error in the sending peer. |
| command-invalid | 503 | hard-error | The client sent an invalid sequence of frames, attempting to perform an operation that was considered invalid by the server. This usually implies a programming error in the client. |
| channel-error | 504 | hard-error | The client attempted to work with a channel that had not been correctly opened. This most likely indicates a fault in the client layer. |
| unexpected-frame | 505 | hard-error | The peer sent a frame that was not expected, usually in the context of a content header and body.  This strongly indicates a fault in the peer's content processing. |
| resource-error | 506 | hard-error | The server could not complete the method because it lacked sufficient resources. This may be due to the client creating too many of some type of entity. |
| not-allowed | 530 | hard-error | The client tried to work with some entity in a manner that is prohibited by the server, due to security settings or by some other criteria. |
| not-implemented | 540 | hard-error | The client tried to use functionality that is not implemented in the server. |
| internal-error | 541 | hard-error | The server could not complete the method because of an internal error. The server may require intervention by an operator in order to resume normal operations. |

## Domains

| Name | Type | Label | Description | Assertions |
|----|----|----|----|----|
| class-id | short |  |  |  |
| consumer-tag | shortstr | consumer tag | Identifier for the consumer, valid within the current channel. |  |
| delivery-tag | longlong | server-assigned delivery tag | The server-assigned and channel-specific delivery tag |  |
| exchange-name | shortstr | exchange name | The exchange name is a client-selected string that identifies the exchange for publish methods. | length 127, regexp ^[a-zA-Z0-9-_.:]*$ |
| method-id | short |  |  |  |
| no-ack | bit | no acknowledgement needed | If this field is set the server does not expect acknowledgements for messages. That is, when a message is delivered to the client the server assumes the delivery will succeed and immediately dequeues it. This functionality may increase performance but at the cost of reliability. Messages can get lost if a client dies before they are delivered to the application. |  |
| no-local | bit | do not deliver own messages | If the no-local field is set the server will not send messages to the connection that published them. |  |
| no-wait | bit | do not send reply method | If set, the server will not respond to the method. The client should not wait for a reply method. If the server could not complete the method it will raise a channel or connection exception. |  |
| path | shortstr |  | Unconstrained. | notnull, length 127 |
| peer-properties | table |  | This table provides a set of peer properties, used for identification, debugging, and general information. |  |
| queue-name | shortstr | queue name | The queue name identifies the queue within the vhost.  In methods where the queue name may be blank, and that has no specific significance, this refers to the 'current' queue for the channel, meaning the last queue that the client declared on the channel.  If the client did not declare a queue, and the method needs a queue name, this will result in a 502 (syntax error) channel exception. | length 127, regexp ^[a-zA-Z0-9-_.:]*$ |
| redelivered | bit | message is being redelivered | This indicates that the message has been previously delivered to this or another client. |  |
| message-count | long | number of messages in queue | The number of messages in the queue, which will be zero for newly-declared queues. This is the number of messages present in the queue, and committed if the channel on which they were published is transacted, that are not waiting acknowledgement. |  |
| reply-code | short | reply code from server | The reply code. The AMQ reply codes are defined as constants at the start of this formal specification. | notnull |
| reply-text | shortstr | localised reply text | The localised reply text. This text can be logged as an aid to resolving issues. | notnull |
| bit | bit | single bit |  |  |
| octet | octet | single octet |  |  |
| short | short | 16-bit integer |  |  |
| long | long | 32-bit integer |  |  |
| longlong | longlong | 64-bit integer |  |  |
| shortstr | shortstr | short string (max. 256 characters) |  |  |
| longstr | longstr | long string |  |  |
| timestamp | timestamp | 64-bit timestamp |  |  |
| table | table | field table |  |  |

## Classes

- [connection](#connection) (10): work with socket connections
- [channel](#channel) (20): work with channels
- [exchange](#exchange) (40): work with exchanges
- [queue](#queue) (50): work with queues
- [basic](#basic) (60): work with basic content
- [tx](#tx) (90): work with transactions
- [confirm](#confirm) (85): work with confirms

## connection

Class id 10: work with socket connections.

The connection class provides methods for a client to establish a network connection to a server, and for both peers to operate the connection thereafter.

```text
connection          = open-connection *use-connection close-connection
open-connection     = C:protocol-header
                      S:START C:START-OK
                      *challenge
                      S:TUNE C:TUNE-OK
                      C:OPEN S:OPEN-OK
challenge           = S:SECURE C:SECURE-OK
use-connection      = *channel
close-connection    = C:CLOSE S:CLOSE-OK
                    / S:CLOSE C:CLOSE-OK
```

Implemented by: server MUST, client MUST.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [connection.start](#connectionstart) | 10 | yes | start-ok | start connection negotiation |
| [connection.start-ok](#connectionstart-ok) | 11 | yes |  | select security mechanism and locale |
| [connection.secure](#connectionsecure) | 20 | yes | secure-ok | security mechanism challenge |
| [connection.secure-ok](#connectionsecure-ok) | 21 | yes |  | security mechanism response |
| [connection.tune](#connectiontune) | 30 | yes | tune-ok | propose connection tuning parameters |
| [connection.tune-ok](#connectiontune-ok) | 31 | yes |  | negotiate connection tuning parameters |
| [connection.open](#connectionopen) | 40 | yes | open-ok | open connection to virtual host |
| [connection.open-ok](#connectionopen-ok) | 41 | yes |  | signal that connection is ready |
| [connection.close](#connectionclose) | 50 | yes | close-ok | request a connection close |
| [connection.close-ok](#connectionclose-ok) | 51 | yes |  | confirm a connection close |
| [connection.blocked](#connectionblocked) | 60 | no |  | indicate that connection is blocked |
| [connection.unblocked](#connectionunblocked) | 61 | no |  | indicate that connection is unblocked |
| [connection.update-secret](#connectionupdate-secret) | 70 | yes | update-secret-ok | update secret |
| [connection.update-secret-ok](#connectionupdate-secret-ok) | 71 | yes |  | update secret response |

### connection.start

Method id 10.10: start connection negotiation.

This method starts the connection negotiation process by telling the client the protocol version that the server proposes, along with a list of security mechanisms which the client can use for authentication.

Implemented by: client MUST. Synchronous, responses: `connection.start-ok`.

**Rule protocol-name**

If the server cannot support the protocol specified in the protocol header, it MUST respond with a valid protocol header and then close the socket connection.

> Test scenario: The client sends a protocol header containing an invalid protocol name. The server MUST respond by sending a valid protocol header and then closing the connection.

**Rule server-support**

The server MUST provide a protocol version that is lower than or equal to that requested by the client in the protocol header.

> Test scenario: The client requests a protocol version that is higher than any valid implementation, e.g. 2.0.  The server must respond with a protocol header indicating its supported protocol version, e.g. 1.0.

**Rule client-support**

If the client cannot handle the protocol version suggested by the server it MUST close the socket connection without sending any further data.

> Test scenario: The server sends a protocol version that is lower than any valid implementation, e.g. 0.1.  The client must respond by closing the connection without sending any further data.

| Field | Domain | Label |
|----|----|----|
| version-major | octet | protocol major version |
| version-minor | octet | protocol minor version |
| server-properties | peer-properties | server properties |
| mechanisms | longstr | available security mechanisms |
| locales | longstr | available message locales |

#### connection.start version-major

The major version number can take any value from 0 to 99 as defined in the AMQP specification.

#### connection.start version-minor

The minor version number can take any value from 0 to 99 as defined in the AMQP specification.

#### connection.start server-properties

**Rule required-fields**

The properties SHOULD contain at least these fields: "host", specifying the server host name or address, "product", giving the name of the server product, "version", giving the name of the server version, "platform", giving the name of the operating system, "copyright", if appropriate, and "information", giving other general information.

> Test scenario: Client connects to server and inspects the server properties. It checks for the presence of the required fields.

#### connection.start mechanisms

A list of the security mechanisms that the server supports, delimited by spaces.

Assertions: notnull.

#### connection.start locales

A list of the message locales that the server supports, delimited by spaces. The locale defines the language in which the server will send reply texts.

Assertions: notnull.

**Rule required-support**

The server MUST support at least the en_US locale.

> Test scenario: Client connects to server and inspects the locales field. It checks for the presence of the required locale(s).

### connection.start-ok

Method id 10.11: select security mechanism and locale.

This method selects a SASL security mechanism.

Implemented by: server MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| client-properties | peer-properties | client properties |
| mechanism | shortstr | selected security mechanism |
| response | longstr | security response data |
| locale | shortstr | selected message locale |

#### connection.start-ok client-properties

**Rule required-fields**

The properties SHOULD contain at least these fields: "product", giving the name of the client product, "version", giving the name of the client version, "platform", giving the name of the operating system, "copyright", if appropriate, and "information", giving other general information.

#### connection.start-ok mechanism

A single security mechanisms selected by the client, which must be one of those specified by the server.

Assertions: notnull.

**Rule security**

The client SHOULD authenticate using the highest-level security profile it can handle from the list provided by the server.

**Rule validity**

If the mechanism field does not contain one of the security mechanisms proposed by the server in the Start method, the server MUST close the connection without sending any further data.

> Test scenario: Client connects to server and sends an invalid security mechanism. The server must respond by closing the connection (a socket close, with no connection close negotiation).

#### connection.start-ok response

A block of opaque data passed to the security mechanism. The contents of this data are defined by the SASL security mechanism.

Assertions: notnull.

#### connection.start-ok locale

A single message locale selected by the client, which must be one of those specified by the server.

Assertions: notnull.

### connection.secure

Method id 10.20: security mechanism challenge.

The SASL protocol works by exchanging challenges and responses until both peers have received sufficient information to authenticate each other. This method challenges the client to provide more information.

Implemented by: client MUST. Synchronous, responses: `connection.secure-ok`.

| Field | Domain | Label |
|----|----|----|
| challenge | longstr | security challenge data |

#### connection.secure challenge

Challenge information, a block of opaque binary data passed to the security mechanism.

### connection.secure-ok

Method id 10.21: security mechanism response.

This method attempts to authenticate, passing a block of SASL data for the security mechanism at the server side.

Implemented by: server MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| response | longstr | security response data |

#### connection.secure-ok response

A block of opaque data passed to the security mechanism. The contents of this data are defined by the SASL security mechanism.

Assertions: notnull.

### connection.tune

Method id 10.30: propose connection tuning parameters.

This method proposes a set of connection configuration values to the client. The client can accept and/or adjust these.

Implemented by: client MUST. Synchronous, responses: `connection.tune-ok`.

| Field | Domain | Label |
|----|----|----|
| channel-max | short | proposed maximum channels |
| frame-max | long | proposed maximum frame size |
| heartbeat | short | desired heartbeat delay |

#### connection.tune channel-max

Specifies highest channel number that the server permits.  Usable channel numbers are in the range 1..channel-max.  Zero indicates no specified limit.

#### connection.tune frame-max

The largest frame size that the server proposes for the connection, including frame header and end-byte.  The client can negotiate a lower value. Zero means that the server does not impose any specific limit but may reject very large frames if it cannot allocate resources for them.

**Rule minimum**

Until the frame-max has been negotiated, both peers MUST accept frames of up to frame-min-size octets large, and the minimum negotiated value for frame-max is also frame-min-size.

> Test scenario: Client connects to server and sends a large properties field, creating a frame of frame-min-size octets.  The server must accept this frame.

#### connection.tune heartbeat

The delay, in seconds, of the connection heartbeat that the server wants. Zero means the server does not want a heartbeat.

### connection.tune-ok

Method id 10.31: negotiate connection tuning parameters.

This method sends the client's connection tuning parameters to the server. Certain fields are negotiated, others provide capability information.

Implemented by: server MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| channel-max | short | negotiated maximum channels |
| frame-max | long | negotiated maximum frame size |
| heartbeat | short | desired heartbeat delay |

#### connection.tune-ok channel-max

The maximum total number of channels that the client will use per connection.

Assertions: notnull, le.

**Rule upper-limit**

If the client specifies a channel max that is higher than the value provided by the server, the server MUST close the connection without attempting a negotiated close.  The server may report the error in some fashion to assist implementors.

#### connection.tune-ok frame-max

The largest frame size that the client and server will use for the connection. Zero means that the client does not impose any specific limit but may reject very large frames if it cannot allocate resources for them. Note that the frame-max limit applies principally to content frames, where large contents can be broken into frames of arbitrary size.

**Rule minimum**

Until the frame-max has been negotiated, both peers MUST accept frames of up to frame-min-size octets large, and the minimum negotiated value for frame-max is also frame-min-size.

**Rule upper-limit**

If the client specifies a frame max that is higher than the value provided by the server, the server MUST close the connection without attempting a negotiated close. The server may report the error in some fashion to assist implementors.

#### connection.tune-ok heartbeat

The delay, in seconds, of the connection heartbeat that the client wants. Zero means the client does not want a heartbeat.

### connection.open

Method id 10.40: open connection to virtual host.

This method opens a connection to a virtual host, which is a collection of resources, and acts to separate multiple application domains within a server. The server may apply arbitrary limits per virtual host, such as the number of each type of entity that may be used, per connection and/or in total.

Implemented by: server MUST. Synchronous, responses: `connection.open-ok`.

| Field | Domain | Label |
|----|----|----|
| virtual-host | path | virtual host name |
| reserved-1 | shortstr | reserved |
| reserved-2 | bit | reserved |

#### connection.open virtual-host

The name of the virtual host to work with.

**Rule separation**

If the server supports multiple virtual hosts, it MUST enforce a full separation of exchanges, queues, and all associated entities per virtual host. An application, connected to a specific virtual host, MUST NOT be able to access resources of another virtual host.

**Rule security**

The server SHOULD verify that the client has permission to access the specified virtual host.

### connection.open-ok

Method id 10.41: signal that connection is ready.

This method signals to the client that the connection is ready for use.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | shortstr | reserved |

### connection.close

Method id 10.50: request a connection close.

This method indicates that the sender wants to close the connection. This may be due to internal conditions (e.g. a forced shut-down) or due to an error handling a specific method, i.e. an exception. When a close is due to an exception, the sender provides the class and method id of the method which caused the exception.

Implemented by: client MUST, server MUST. Synchronous, responses: `connection.close-ok`.

**Rule stability**

After sending this method, any received methods except Close and Close-OK MUST be discarded.  The response to receiving a Close after sending Close must be to send Close-Ok.

| Field | Domain | Label |
|----|----|----|
| reply-code | reply-code | reply code from server |
| reply-text | reply-text | localised reply text |
| class-id | class-id | failing method class |
| method-id | method-id | failing method ID |

#### connection.close class-id

When the close is provoked by a method exception, this is the class of the method.

#### connection.close method-id

When the close is provoked by a method exception, this is the ID of the method.

### connection.close-ok

Method id 10.51: confirm a connection close.

This method confirms a Connection.Close method and tells the recipient that it is safe to release resources for the connection and close the socket.

Implemented by: client MUST, server MUST. Synchronous.

**Rule reporting**

A peer that detects a socket closure without having received a Close-Ok handshake method SHOULD log the error.

### connection.blocked

Method id 10.60: indicate that connection is blocked.

This method indicates that a connection has been blocked and does not accept new publishes.

Implemented by: server MUST, client MUST.

| Field | Domain | Label |
|----|----|----|
| reason | shortstr | Block reason |

#### connection.blocked reason

The reason the connection was blocked.

### connection.unblocked

Method id 10.61: indicate that connection is unblocked.

This method indicates that a connection has been unblocked and now accepts publishes.

Implemented by: server MUST, client MUST.

### connection.update-secret

Method id 10.70: update secret.

This method updates the secret used to authenticate this connection. It is used when secrets have an expiration date and need to be renewed, like OAuth 2 tokens.

Implemented by: client MUST. Synchronous, responses: `connection.update-secret-ok`.

| Field | Domain | Label |
|----|----|----|
| new-secret | longstr | new secret |
| reason | shortstr | reason |

#### connection.update-secret new-secret

The new secret.

#### connection.update-secret reason

The reason for the secret update.

### connection.update-secret-ok

Method id 10.71: update secret response.

This method confirms the updated secret is valid.

Implemented by: server MUST. Synchronous.

## channel

Class id 20: work with channels.

The channel class provides methods for a client to establish a channel to a server and for both peers to operate the channel thereafter.

```text
channel             = open-channel *use-channel close-channel
open-channel        = C:OPEN S:OPEN-OK
use-channel         = C:FLOW S:FLOW-OK
                    / S:FLOW C:FLOW-OK
                    / functional-class
close-channel       = C:CLOSE S:CLOSE-OK
                    / S:CLOSE C:CLOSE-OK
```

Implemented by: server MUST, client MUST.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [channel.open](#channelopen) | 10 | yes | open-ok | open a channel for use |
| [channel.open-ok](#channelopen-ok) | 11 | yes |  | signal that the channel is ready |
| [channel.flow](#channelflow) | 20 | yes | flow-ok | enable/disable flow from peer |
| [channel.flow-ok](#channelflow-ok) | 21 | no |  | confirm a flow method |
| [channel.close](#channelclose) | 40 | yes | close-ok | request a channel close |
| [channel.close-ok](#channelclose-ok) | 41 | yes |  | confirm a channel close |

### channel.open

Method id 20.10: open a channel for use.

This method opens a channel to the server.

Implemented by: server MUST. Synchronous, responses: `channel.open-ok`.

**Rule state** (on failure: `channel-error`)

The client MUST NOT use this method on an already-opened channel.

> Test scenario: Client opens a channel and then reopens the same channel.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | shortstr | reserved |

### channel.open-ok

Method id 20.11: signal that the channel is ready.

This method signals to the client that the channel is ready for use.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | longstr | reserved |

### channel.flow

Method id 20.20: enable/disable flow from peer.

This method asks the peer to pause or restart the flow of content data sent by a consumer. This is a simple flow-control mechanism that a peer can use to avoid overflowing its queues or otherwise finding itself receiving more messages than it can process. Note that this method is not intended for window control. It does not affect contents returned by Basic.Get-Ok methods.

Implemented by: server MUST, client MUST. Synchronous, responses: `channel.flow-ok`.

**Rule initial-state**

When a new channel is opened, it is active (flow is active). Some applications assume that channels are inactive until started. To emulate this behaviour a client MAY open the channel, then pause it.

**Rule bidirectional**

When sending content frames, a peer SHOULD monitor the channel for incoming methods and respond to a Channel.Flow as rapidly as possible.

**Rule throttling**

A peer MAY use the Channel.Flow method to throttle incoming content data for internal reasons, for example, when exchanging data over a slower connection.

**Rule expected-behaviour**

The peer that requests a Channel.Flow method MAY disconnect and/or ban a peer that does not respect the request.  This is to prevent badly-behaved clients from overwhelming a server.

| Field | Domain | Label |
|----|----|----|
| active | bit | start/stop content frames |

#### channel.flow active

If 1, the peer starts sending content frames. If 0, the peer stops sending content frames.

### channel.flow-ok

Method id 20.21: confirm a flow method.

Confirms to the peer that a flow command was received and processed.

Implemented by: server MUST, client MUST.

| Field | Domain | Label |
|----|----|----|
| active | bit | current flow setting |

#### channel.flow-ok active

Confirms the setting of the processed flow method: 1 means the peer will start sending or continue to send content frames; 0 means it will not.

### channel.close

Method id 20.40: request a channel close.

This method indicates that the sender wants to close the channel. This may be due to internal conditions (e.g. a forced shut-down) or due to an error handling a specific method, i.e. an exception. When a close is due to an exception, the sender provides the class and method id of the method which caused the exception.

Implemented by: client MUST, server MUST. Synchronous, responses: `channel.close-ok`.

**Rule stability**

After sending this method, any received methods except Close and Close-OK MUST be discarded.  The response to receiving a Close after sending Close must be to send Close-Ok.

| Field | Domain | Label |
|----|----|----|
| reply-code | reply-code | reply code from server |
| reply-text | reply-text | localised reply text |
| class-id | class-id | failing method class |
| method-id | method-id | failing method ID |

#### channel.close class-id

When the close is provoked by a method exception, this is the class of the method.

#### channel.close method-id

When the close is provoked by a method exception, this is the ID of the method.

### channel.close-ok

Method id 20.41: confirm a channel close.

This method confirms a Channel.Close method and tells the recipient that it is safe to release resources for the channel.

Implemented by: client MUST, server MUST. Synchronous.

**Rule reporting**

A peer that detects a socket closure without having received a Channel.Close-Ok handshake method SHOULD log the error.

## exchange

Class id 40: work with exchanges.

Exchanges match and distribute messages across queues. Exchanges can be configured in the server or declared at runtime.

```text
exchange            = C:DECLARE  S:DECLARE-OK
                    / C:DELETE   S:DELETE-OK
                    / C:BIND     S:BIND-OK
                    / C:UNBIND   S:UNBIND-OK
```

Implemented by: server MUST, client MUST.

**Rule required-types**

The server MUST implement these standard exchange types: fanout, direct.

> Test scenario: Client attempts to declare an exchange with each of these standard types.

**Rule recommended-types**

The server SHOULD implement these standard exchange types: topic, headers.

> Test scenario: Client attempts to declare an exchange with each of these standard types.

**Rule required-instances**

The server MUST, in each virtual host, pre-declare an exchange instance for each standard exchange type that it implements, where the name of the exchange instance, if defined, is "amq." followed by the exchange type name.

The server MUST, in each virtual host, pre-declare at least two direct exchange instances: one named "amq.direct", the other with no public name that serves as a default  exchange for Publish methods.

> Test scenario: Client declares a temporary queue and attempts to bind to each required exchange instance ("amq.fanout", "amq.direct", "amq.topic", and "amq.headers" if those types are defined).

**Rule default-exchange**

The server MUST pre-declare a direct exchange with no public name to act as the default exchange for content Publish methods and for default queue bindings.

> Test scenario: Client checks that the default exchange is active by specifying a queue binding with no exchange name, and publishing a message with a suitable routing key but without specifying the exchange name, then ensuring that the message arrives in the queue correctly.

**Rule default-access**

The server MUST NOT allow clients to access the default exchange except by specifying an empty exchange name in the Queue.Bind and content Publish methods.

**Rule extensions**

The server MAY implement other exchange types as wanted.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [exchange.declare](#exchangedeclare) | 10 | yes | declare-ok | verify exchange exists, create if needed |
| [exchange.declare-ok](#exchangedeclare-ok) | 11 | yes |  | confirm exchange declaration |
| [exchange.delete](#exchangedelete) | 20 | yes | delete-ok | delete an exchange |
| [exchange.delete-ok](#exchangedelete-ok) | 21 | yes |  | confirm deletion of an exchange |
| [exchange.bind](#exchangebind) | 30 | yes | bind-ok | bind exchange to an exchange (RabbitMQ extension) |
| [exchange.bind-ok](#exchangebind-ok) | 31 | yes |  | confirm bind successful (RabbitMQ extension) |
| [exchange.unbind](#exchangeunbind) | 40 | yes | unbind-ok | unbind an exchange from an exchange (RabbitMQ extension) |
| [exchange.unbind-ok](#exchangeunbind-ok) | 51 | yes |  | confirm unbind successful (RabbitMQ extension) |

### exchange.declare

Method id 40.10: verify exchange exists, create if needed.

This method creates an exchange if it does not already exist, and if the exchange exists, verifies that it is of the correct and expected class.

Implemented by: server MUST. Synchronous, responses: `exchange.declare-ok`.

**Rule minimum**

The server SHOULD support a minimum of 16 exchanges per virtual host and ideally, impose no limit except as defined by available resources.

> Test scenario: The client declares as many exchanges as it can until the server reports an error; the number of exchanges successfully declared must be at least sixteen.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| exchange | exchange-name | exchange name |
| type | shortstr | exchange type |
| passive | bit | do not create exchange |
| durable | bit | request a durable exchange |
| auto-delete | bit | auto-delete when unused |
| internal | bit | create internal exchange |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments for declaration |

#### exchange.declare exchange

Assertions: notnull.

**Rule reserved** (on failure: `access-refused`)

Exchange names starting with "amq." are reserved for pre-declared and standardised exchanges. The client MAY declare an exchange starting with "amq." if the passive option is set, or the exchange already exists.

> Test scenario: The client attempts to declare a non-existing exchange starting with "amq." and with the passive option set to zero.

**Rule syntax** (on failure: `precondition-failed`)

The exchange name consists of a non-empty sequence of these characters: letters, digits, hyphen, underscore, period, or colon.

> Test scenario: The client attempts to declare an exchange with an illegal name.

#### exchange.declare type

Each exchange belongs to one of a set of exchange types implemented by the server. The exchange types define the functionality of the exchange - i.e. how messages are routed through it. It is not valid or meaningful to attempt to change the type of an existing exchange.

**Rule typed** (on failure: `not-allowed`)

Exchanges cannot be redeclared with different types.  The client MUST not attempt to redeclare an existing exchange with a different type than used in the original Exchange.Declare method.

> Test scenario: TODO.

**Rule support** (on failure: `command-invalid`)

The client MUST NOT attempt to declare an exchange with a type that the server does not support.

> Test scenario: TODO.

#### exchange.declare passive

If set, the server will reply with Declare-Ok if the exchange already exists with the same name, and raise an error if not.  The client can use this to check whether an exchange exists without modifying the server state. When set, all other method fields except name and no-wait are ignored.  A declare with both passive and no-wait has no effect. Arguments are compared for semantic equivalence.

**Rule not-found**

If set, and the exchange does not already exist, the server MUST raise a channel exception with reply code 404 (not found).

> Test scenario: TODO.

**Rule equivalent**

If not set and the exchange exists, the server MUST check that the existing exchange has the same values for type, durable, and arguments fields.  The server MUST respond with Declare-Ok if the requested exchange matches these fields, and MUST raise a channel exception if not.

> Test scenario: TODO.

#### exchange.declare durable

If set when creating a new exchange, the exchange will be marked as durable. Durable exchanges remain active when a server restarts. Non-durable exchanges (transient exchanges) are purged if/when a server restarts.

**Rule support**

The server MUST support both durable and transient exchanges.

> Test scenario: TODO.

#### exchange.declare auto-delete

If set, the exchange is deleted when all queues have finished using it.

**Rule amq_exchange_02**

The server SHOULD allow for a reasonable delay between the point when it determines that an exchange is not being used (or no longer used), and the point when it deletes the exchange.  At the least it must allow a client to create an exchange and then bind a queue to it, with a small but non-zero delay between these two actions.

**Rule amq_exchange_25**

The server MUST ignore the auto-delete field if the exchange already exists.

#### exchange.declare internal

If set, the exchange may not be used directly by publishers, but only when bound to other exchanges. Internal exchanges are used to construct wiring that is not visible to applications.

#### exchange.declare arguments

A set of arguments for the declaration. The syntax and semantics of these arguments depends on the server implementation.

### exchange.declare-ok

Method id 40.11: confirm exchange declaration.

This method confirms a Declare method and confirms the name of the exchange, essential for automatically-named exchanges.

Implemented by: client MUST. Synchronous.

### exchange.delete

Method id 40.20: delete an exchange.

This method deletes an exchange. When an exchange is deleted all queue bindings on the exchange are cancelled.

Implemented by: server MUST. Synchronous, responses: `exchange.delete-ok`.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| exchange | exchange-name | exchange name |
| if-unused | bit | delete only if unused |
| no-wait | no-wait | do not send reply method |

#### exchange.delete exchange

Assertions: notnull.

**Rule exists** (on failure: `not-found`)

The client MUST NOT attempt to delete an exchange that does not exist.

#### exchange.delete if-unused

If set, the server will only delete the exchange if it has no queue bindings. If the exchange has queue bindings the server does not delete it but raises a channel exception instead.

**Rule in-use** (on failure: `precondition-failed`)

The server MUST NOT delete an exchange that has bindings on it, if the if-unused field is true.

> Test scenario: The client declares an exchange, binds a queue to it, then tries to delete it setting if-unused to true.

### exchange.delete-ok

Method id 40.21: confirm deletion of an exchange.

This method confirms the deletion of an exchange.

Implemented by: client MUST. Synchronous.

### exchange.bind

Method id 40.30: bind exchange to an exchange.

*RabbitMQ extension.*

This method binds an exchange to an exchange.

Implemented by: server MUST. Synchronous, responses: `exchange.bind-ok`.

**Rule duplicates**

A server MUST allow and ignore duplicate bindings - that is, two or more bind methods for a specific exchanges, with identical arguments - without treating these as an error.

> Test scenario: A client binds an exchange to an exchange. The client then repeats the bind (with identical arguments).

**Rule cyclical**

A server MUST allow cycles of exchange bindings to be created including allowing an exchange to be bound to itself.

> Test scenario: A client declares an exchange and binds it to itself.

**Rule unique**

A server MUST not deliver the same message more than once to a destination exchange, even if the topology of exchanges and bindings results in multiple (even infinite) routes to that exchange.

> Test scenario: A client declares an exchange and binds it using multiple bindings to the amq.topic exchange. The client then publishes a message to the amq.topic exchange that matches all the bindings.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| destination | exchange-name | name of the destination exchange to bind to |
| source | exchange-name | name of the source exchange to bind to |
| routing-key | shortstr | message routing key |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments for binding |

#### exchange.bind destination

Specifies the name of the destination exchange to bind.

**Rule exchange-existence** (on failure: `not-found`)

A client MUST NOT be allowed to bind a non-existent destination exchange.

> Test scenario: A client attempts to bind an undeclared exchange to an exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares an exchange and binds a blank exchange name to it.

#### exchange.bind source

Specifies the name of the source exchange to bind.

**Rule exchange-existence** (on failure: `not-found`)

A client MUST NOT be allowed to bind a non-existent source exchange.

> Test scenario: A client attempts to bind an exchange to an undeclared exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares an exchange and binds it to a blank exchange name.

#### exchange.bind routing-key

Specifies the routing key for the binding. The routing key is used for routing messages depending on the exchange configuration. Not all exchanges use a routing key - refer to the specific exchange documentation.

#### exchange.bind arguments

A set of arguments for the binding. The syntax and semantics of these arguments depends on the exchange class.

### exchange.bind-ok

Method id 40.31: confirm bind successful.

*RabbitMQ extension.*

This method confirms that the bind was successful.

Implemented by: client MUST. Synchronous.

### exchange.unbind

Method id 40.40: unbind an exchange from an exchange.

*RabbitMQ extension.*

This method unbinds an exchange from an exchange.

Implemented by: server MUST. Synchronous, responses: `exchange.unbind-ok`.

**Rule 01**

If a unbind fails, the server MUST raise a connection exception.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| destination | exchange-name | exchange name |
| source | exchange-name | exchange name |
| routing-key | shortstr | routing key of binding |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments of binding |

#### exchange.unbind destination

Specifies the name of the destination exchange to unbind.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to unbind an exchange that does not exist from an exchange.

> Test scenario: The client attempts to unbind a non-existent exchange from an exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares an exchange, binds a blank exchange name to it, and then unbinds a blank exchange name from it.

#### exchange.unbind source

Specifies the name of the source exchange to unbind.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to unbind an exchange from an exchange that does not exist.

> Test scenario: The client attempts to unbind an exchange from a non-existent exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares an exchange, binds an exchange to a blank exchange name, and then unbinds an exchange from a black exchange name.

#### exchange.unbind routing-key

Specifies the routing key of the binding to unbind.

#### exchange.unbind arguments

Specifies the arguments of the binding to unbind.

### exchange.unbind-ok

Method id 40.51: confirm unbind successful.

*RabbitMQ extension.*

This method confirms that the unbind was successful.

Implemented by: client MUST. Synchronous.

## queue

Class id 50: work with queues.

Queues store and forward messages. Queues can be configured in the server or created at runtime. Queues must be attached to at least one exchange in order to receive messages from publishers.

```text
queue               = C:DECLARE  S:DECLARE-OK
                    / C:BIND     S:BIND-OK
                    / C:UNBIND   S:UNBIND-OK
                    / C:PURGE    S:PURGE-OK
                    / C:DELETE   S:DELETE-OK
```

Implemented by: server MUST, client MUST.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [queue.declare](#queuedeclare) | 10 | yes | declare-ok | declare queue, create if needed |
| [queue.declare-ok](#queuedeclare-ok) | 11 | yes |  | confirms a queue definition |
| [queue.bind](#queuebind) | 20 | yes | bind-ok | bind queue to an exchange |
| [queue.bind-ok](#queuebind-ok) | 21 | yes |  | confirm bind successful |
| [queue.unbind](#queueunbind) | 50 | yes | unbind-ok | unbind a queue from an exchange |
| [queue.unbind-ok](#queueunbind-ok) | 51 | yes |  | confirm unbind successful |
| [queue.purge](#queuepurge) | 30 | yes | purge-ok | purge a queue |
| [queue.purge-ok](#queuepurge-ok) | 31 | yes |  | confirms a queue purge |
| [queue.delete](#queuedelete) | 40 | yes | delete-ok | delete a queue |
| [queue.delete-ok](#queuedelete-ok) | 41 | yes |  | confirm deletion of a queue |

### queue.declare

Method id 50.10: declare queue, create if needed.

This method creates or checks a queue. When creating a new queue the client can specify various properties that control the durability of the queue and its contents, and the level of sharing for the queue.

Implemented by: server MUST. Synchronous, responses: `queue.declare-ok`.

**Rule default-binding**

The server MUST create a default binding for a newly-declared queue to the default exchange, which is an exchange of type 'direct' and use the queue name as the routing key.

> Test scenario: Client declares a new queue, and then without explicitly binding it to an exchange, attempts to send a message through the default exchange binding, i.e. publish a message to the empty exchange, with the queue name as routing key.

**Rule minimum-queues**

The server SHOULD support a minimum of 256 queues per virtual host and ideally, impose no limit except as defined by available resources.

> Test scenario: Client attempts to declare as many queues as it can until the server reports an error.  The resulting count must at least be 256.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| passive | bit | do not create queue |
| durable | bit | request a durable queue |
| exclusive | bit | request an exclusive queue |
| auto-delete | bit | auto-delete queue when unused |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments for declaration |

#### queue.declare queue

**Rule default-name**

The queue name MAY be empty, in which case the server MUST create a new queue with a unique generated name and return this to the client in the Declare-Ok method.

> Test scenario: Client attempts to declare several queues with an empty name. The client then verifies that the server-assigned names are unique and different.

**Rule reserved** (on failure: `access-refused`)

Queue names starting with "amq." are reserved for pre-declared and standardised queues. The client MAY declare a queue starting with "amq." if the passive option is set, or the queue already exists.

> Test scenario: The client attempts to declare a non-existing queue starting with "amq." and with the passive option set to zero.

**Rule syntax** (on failure: `precondition-failed`)

The queue name can be empty, or a sequence of these characters: letters, digits, hyphen, underscore, period, or colon.

> Test scenario: The client attempts to declare a queue with an illegal name.

#### queue.declare passive

If set, the server will reply with Declare-Ok if the queue already exists with the same name, and raise an error if not.  The client can use this to check whether a queue exists without modifying the server state.  When set, all other method fields except name and no-wait are ignored.  A declare with both passive and no-wait has no effect. Arguments are compared for semantic equivalence.

**Rule passive** (on failure: `not-found`)

The client MAY ask the server to assert that a queue exists without creating the queue if not.  If the queue does not exist, the server treats this as a failure.

> Test scenario: Client declares an existing queue with the passive option and expects the server to respond with a declare-ok. Client then attempts to declare a non-existent queue with the passive option, and the server must close the channel with the correct reply-code.

**Rule equivalent**

If not set and the queue exists, the server MUST check that the existing queue has the same values for durable, exclusive, auto-delete, and arguments fields.  The server MUST respond with Declare-Ok if the requested queue matches these fields, and MUST raise a channel exception if not.

> Test scenario: TODO.

#### queue.declare durable

If set when creating a new queue, the queue will be marked as durable. Durable queues remain active when a server restarts. Non-durable queues (transient queues) are purged if/when a server restarts. Note that durable queues do not necessarily hold persistent messages, although it does not make sense to send persistent messages to a transient queue.

**Rule persistence**

The server MUST recreate the durable queue after a restart.

> Test scenario: Client declares a durable queue. The server is then restarted. The client then attempts to send a message to the queue. The message should be successfully delivered.

**Rule types**

The server MUST support both durable and transient queues.

> Test scenario: A client declares two named queues, one durable and one transient.

#### queue.declare exclusive

Exclusive queues may only be accessed by the current connection, and are deleted when that connection closes.  Passive declaration of an exclusive queue by other connections are not allowed.

**Rule types**

The server MUST support both exclusive (private) and non-exclusive (shared) queues.

> Test scenario: A client declares two named queues, one exclusive and one non-exclusive.

**Rule exclusive** (on failure: `resource-locked`)

The client MAY NOT attempt to use a queue that was declared as exclusive by another still-open connection.

> Test scenario: One client declares an exclusive queue. A second client on a different connection attempts to declare, bind, consume, purge, delete, or declare a queue of the same name.

#### queue.declare auto-delete

If set, the queue is deleted when all consumers have finished using it.  The last consumer can be cancelled either explicitly or because its channel is closed. If there was no consumer ever on the queue, it won't be deleted.  Applications can explicitly delete auto-delete queues using the Delete method as normal.

**Rule pre-existence**

The server MUST ignore the auto-delete field if the queue already exists.

> Test scenario: Client declares two named queues, one as auto-delete and one explicit-delete. Client then attempts to declare the two queues using the same names again, but reversing the value of the auto-delete field in each case. Verify that the queues still exist with the original auto-delete flag values.

#### queue.declare arguments

A set of arguments for the declaration. The syntax and semantics of these arguments depends on the server implementation.

### queue.declare-ok

Method id 50.11: confirms a queue definition.

This method confirms a Declare method and confirms the name of the queue, essential for automatically-named queues.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| queue | queue-name | queue name |
| message-count | message-count | number of messages in queue |
| consumer-count | long | number of consumers |

#### queue.declare-ok queue

Reports the name of the queue. If the server generated a queue name, this field contains that name.

Assertions: notnull.

#### queue.declare-ok consumer-count

Reports the number of active consumers for the queue. Note that consumers can suspend activity (Channel.Flow) in which case they do not appear in this count.

### queue.bind

Method id 50.20: bind queue to an exchange.

This method binds a queue to an exchange. Until a queue is bound it will not receive any messages. In a classic messaging model, store-and-forward queues are bound to a direct exchange and subscription queues are bound to a topic exchange.

Implemented by: server MUST. Synchronous, responses: `queue.bind-ok`.

**Rule duplicates**

A server MUST allow ignore duplicate bindings - that is, two or more bind methods for a specific queue, with identical arguments - without treating these as an error.

> Test scenario: A client binds a named queue to an exchange. The client then repeats the bind (with identical arguments).

**Rule unique**

A server MUST not deliver the same message more than once to a queue, even if the queue has multiple bindings that match the message.

> Test scenario: A client declares a named queue and binds it using multiple bindings to the amq.topic exchange. The client then publishes a message that matches all its bindings.

**Rule transient-exchange**

The server MUST allow a durable queue to bind to a transient exchange.

> Test scenario: A client declares a transient exchange. The client then declares a named durable queue and then attempts to bind the transient exchange to the durable queue.

**Rule durable-exchange**

Bindings of durable queues to durable exchanges are automatically durable and the server MUST restore such bindings after a server restart.

> Test scenario: A server declares a named durable queue and binds it to a durable exchange. The server is restarted. The client then attempts to use the queue/exchange combination.

**Rule binding-count**

The server SHOULD support at least 4 bindings per queue, and ideally, impose no limit except as defined by available resources.

> Test scenario: A client declares a named queue and attempts to bind it to 4 different exchanges.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| exchange | exchange-name | name of the exchange to bind to |
| routing-key | shortstr | message routing key |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments for binding |

#### queue.bind queue

Specifies the name of the queue to bind.

**Rule queue-known** (on failure: `not-found`)

The client MUST either specify a queue name or have previously declared a queue on the same channel

> Test scenario: The client opens a channel and attempts to bind an unnamed queue.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to bind a queue that does not exist.

> Test scenario: The client attempts to bind a non-existent queue.

#### queue.bind exchange

**Rule exchange-existence** (on failure: `not-found`)

A client MUST NOT be allowed to bind a queue to a non-existent exchange.

> Test scenario: A client attempts to bind an named queue to a undeclared exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares a queue and binds it to a blank exchange name.

#### queue.bind routing-key

Specifies the routing key for the binding. The routing key is used for routing messages depending on the exchange configuration. Not all exchanges use a routing key - refer to the specific exchange documentation.  If the queue name is empty, the server uses the last queue declared on the channel.  If the routing key is also empty, the server uses this queue name for the routing key as well.  If the queue name is provided but the routing key is empty, the server does the binding with that empty routing key.  The meaning of empty routing keys depends on the exchange implementation.

**Rule direct-exchange-key-matching**

If a message queue binds to a direct exchange using routing key K and a publisher sends the exchange a message with routing key R, then the message MUST be passed to the message queue if K = R.

#### queue.bind arguments

A set of arguments for the binding. The syntax and semantics of these arguments depends on the exchange class.

### queue.bind-ok

Method id 50.21: confirm bind successful.

This method confirms that the bind was successful.

Implemented by: client MUST. Synchronous.

### queue.unbind

Method id 50.50: unbind a queue from an exchange.

This method unbinds a queue from an exchange.

Implemented by: server MUST. Synchronous, responses: `queue.unbind-ok`.

**Rule 01**

If a unbind fails, the server MUST raise a connection exception.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| exchange | exchange-name | exchange name |
| routing-key | shortstr | routing key of binding |
| arguments | table | arguments of binding |

#### queue.unbind queue

Specifies the name of the queue to unbind.

**Rule queue-known** (on failure: `not-found`)

The client MUST either specify a queue name or have previously declared a queue on the same channel

> Test scenario: The client opens a channel and attempts to unbind an unnamed queue.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to unbind a queue that does not exist.

> Test scenario: The client attempts to unbind a non-existent queue.

#### queue.unbind exchange

The name of the exchange to unbind from.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to unbind a queue from an exchange that does not exist.

> Test scenario: The client attempts to unbind a queue from a non-existent exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares a queue and binds it to a blank exchange name.

#### queue.unbind routing-key

Specifies the routing key of the binding to unbind.

#### queue.unbind arguments

Specifies the arguments of the binding to unbind.

### queue.unbind-ok

Method id 50.51: confirm unbind successful.

This method confirms that the unbind was successful.

Implemented by: client MUST. Synchronous.

### queue.purge

Method id 50.30: purge a queue.

This method removes all messages from a queue which are not awaiting acknowledgment.

Implemented by: server MUST. Synchronous, responses: `queue.purge-ok`.

**Rule 02**

The server MUST NOT purge messages that have already been sent to a client but not yet acknowledged.

**Rule 03**

The server MAY implement a purge queue or log that allows system administrators to recover accidentally-purged messages. The server SHOULD NOT keep purged messages in the same storage spaces as the live messages since the volumes of purged messages may get very large.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| no-wait | no-wait | do not send reply method |

#### queue.purge queue

Specifies the name of the queue to purge.

**Rule queue-known** (on failure: `not-found`)

The client MUST either specify a queue name or have previously declared a queue on the same channel

> Test scenario: The client opens a channel and attempts to purge an unnamed queue.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to purge a queue that does not exist.

> Test scenario: The client attempts to purge a non-existent queue.

### queue.purge-ok

Method id 50.31: confirms a queue purge.

This method confirms the purge of a queue.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| message-count | message-count | number of messages in queue |

#### queue.purge-ok message-count

Reports the number of messages purged.

### queue.delete

Method id 50.40: delete a queue.

This method deletes a queue. When a queue is deleted any pending messages are sent to a dead-letter queue if this is defined in the server configuration, and all consumers on the queue are cancelled.

Implemented by: server MUST. Synchronous, responses: `queue.delete-ok`.

**Rule 01**

The server SHOULD use a dead-letter queue to hold messages that were pending on a deleted queue, and MAY provide facilities for a system administrator to move these messages back to an active queue.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| if-unused | bit | delete only if unused |
| if-empty | bit | delete only if empty |
| no-wait | no-wait | do not send reply method |

#### queue.delete queue

Specifies the name of the queue to delete.

**Rule queue-known** (on failure: `not-found`)

The client MUST either specify a queue name or have previously declared a queue on the same channel

> Test scenario: The client opens a channel and attempts to delete an unnamed queue.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to delete a queue that does not exist.

> Test scenario: The client attempts to delete a non-existent queue.

#### queue.delete if-unused

If set, the server will only delete the queue if it has no consumers. If the queue has consumers the server does does not delete it but raises a channel exception instead.

**Rule in-use** (on failure: `precondition-failed`)

The server MUST NOT delete a queue that has consumers on it, if the if-unused field is true.

> Test scenario: The client declares a queue, and consumes from it, then tries to delete it setting if-unused to true.

#### queue.delete if-empty

If set, the server will only delete the queue if it has no messages.

**Rule not-empty** (on failure: `precondition-failed`)

The server MUST NOT delete a queue that has messages on it, if the if-empty field is true.

> Test scenario: The client declares a queue, binds it and publishes some messages into it, then tries to delete it setting if-empty to true.

### queue.delete-ok

Method id 50.41: confirm deletion of a queue.

This method confirms the deletion of a queue.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| message-count | message-count | number of messages in queue |

#### queue.delete-ok message-count

Reports the number of messages deleted.

## basic

Class id 60: work with basic content.

The Basic class provides methods that support an industry-standard messaging model.

```text
basic               = C:QOS S:QOS-OK
                    / C:CONSUME S:CONSUME-OK
                    / C:CANCEL S:CANCEL-OK
                    / C:PUBLISH content
                    / S:RETURN content
                    / S:DELIVER content
                    / C:GET ( S:GET-OK content / S:GET-EMPTY )
                    / C:ACK
                    / S:ACK
                    / C:REJECT
                    / C:NACK
                    / S:NACK
                    / C:RECOVER-ASYNC
                    / C:RECOVER S:RECOVER-OK
```

Implemented by: server MUST, client MAY.

**Rule 01**

The server SHOULD respect the persistent property of basic messages and SHOULD make a best-effort to hold persistent basic messages on a reliable storage mechanism.

> Test scenario: Send a persistent message to queue, stop server, restart server and then verify whether message is still present.  Assumes that queues are durable. Persistence without durable queues makes no sense.

**Rule 02**

The server MUST NOT discard a persistent basic message in case of a queue overflow.

> Test scenario: Declare a queue overflow situation with persistent messages and verify that messages do not get lost (presumably the server will write them to disk).

**Rule 03**

The server MAY use the Channel.Flow method to slow or stop a basic message publisher when necessary.

> Test scenario: Declare a queue overflow situation with non-persistent messages and verify whether the server responds with Channel.Flow or not. Repeat with persistent messages.

**Rule 04**

The server MAY overflow non-persistent basic messages to persistent storage.

**Rule 05**

The server MAY discard or dead-letter non-persistent basic messages on a priority basis if the queue size exceeds some configured limit.

**Rule 06**

The server MUST implement at least 2 priority levels for basic messages, where priorities 0-4 and 5-9 are treated as two distinct levels.

> Test scenario: Send a number of priority 0 messages to a queue. Send one priority 9 message.  Consume messages from the queue and verify that the first message received was priority 9.

**Rule 07**

The server MAY implement up to 10 priority levels.

> Test scenario: Send a number of messages with mixed priorities to a queue, so that all priority values from 0 to 9 are exercised. A good scenario would be ten messages in low-to-high priority.  Consume from queue and verify how many priority levels emerge.

**Rule 08**

The server MUST deliver messages of the same priority in order irrespective of their individual persistence.

> Test scenario: Send a set of messages with the same priority but different persistence settings to a queue.  Consume and verify that messages arrive in same order as originally published.

**Rule 09**

The server MUST support un-acknowledged delivery of Basic content, i.e. consumers with the no-ack field set to TRUE.

**Rule 10**

The server MUST support explicitly acknowledged delivery of Basic content, i.e. consumers with the no-ack field set to FALSE.

> Test scenario: Declare a queue and a consumer using explicit acknowledgements.  Publish a set of messages to the queue.  Consume the messages but acknowledge only half of them.  Disconnect and reconnect, and consume from the queue. Verify that the remaining messages are received.

Content properties, in property flag order:

| Property | Domain | Label |
|----|----|----|
| content-type | shortstr | MIME content type |
| content-encoding | shortstr | MIME content encoding |
| headers | table | message header field table |
| delivery-mode | octet | non-persistent (1) or persistent (2) |
| priority | octet | message priority, 0 to 9 |
| correlation-id | shortstr | application correlation identifier |
| reply-to | shortstr | address to reply to |
| expiration | shortstr | message expiration specification |
| message-id | shortstr | application message identifier |
| timestamp | timestamp | message timestamp |
| type | shortstr | message type name |
| user-id | shortstr | creating user id |
| app-id | shortstr | creating application id |
| reserved | shortstr | reserved, must be empty |

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [basic.qos](#basicqos) | 10 | yes | qos-ok | specify quality of service |
| [basic.qos-ok](#basicqos-ok) | 11 | yes |  | confirm the requested qos |
| [basic.consume](#basicconsume) | 20 | yes | consume-ok | start a queue consumer |
| [basic.consume-ok](#basicconsume-ok) | 21 | yes |  | confirm a new consumer |
| [basic.cancel](#basiccancel) | 30 | yes | cancel-ok | end a queue consumer |
| [basic.cancel-ok](#basiccancel-ok) | 31 | yes |  | confirm a cancelled consumer |
| [basic.publish](#basicpublish) | 40 | no |  | publish a message |
| [basic.return](#basicreturn) | 50 | no |  | return a failed message |
| [basic.deliver](#basicdeliver) | 60 | no |  | notify the client of a consumer message |
| [basic.get](#basicget) | 70 | yes | get-ok, get-empty | direct access to a queue |
| [basic.get-ok](#basicget-ok) | 71 | yes |  | provide client with a message |
| [basic.get-empty](#basicget-empty) | 72 | yes |  | indicate no messages available |
| [basic.ack](#basicack) | 80 | no |  | acknowledge one or more messages |
| [basic.reject](#basicreject) | 90 | no |  | reject an incoming message |
| [basic.recover-async](#basicrecover-async) | 100 | no |  | redeliver unacknowledged messages |
| [basic.recover](#basicrecover) | 110 | no |  | redeliver unacknowledged messages |
| [basic.recover-ok](#basicrecover-ok) | 111 | yes |  | confirm recovery |
| [basic.nack](#basicnack) | 120 | no |  | reject one or more incoming messages (RabbitMQ extension) |

### basic.qos

Method id 60.10: specify quality of service.

This method requests a specific quality of service. The QoS can be specified for the current channel or for all channels on the connection. The particular properties and semantics of a qos method always depend on the content class semantics. Though the qos method could in principle apply to both peers, it is currently meaningful only for the server.

Implemented by: server MUST. Synchronous, responses: `basic.qos-ok`.

| Field | Domain | Label |
|----|----|----|
| prefetch-size | long | prefetch window in octets |
| prefetch-count | short | prefetch window in messages |
| global | bit | apply to entire connection |

#### basic.qos prefetch-size

The client can request that messages be sent in advance so that when the client finishes processing a message, the following message is already held locally, rather than needing to be sent down the channel. Prefetching gives a performance improvement. This field specifies the prefetch window size in octets. The server will send a message in advance if it is equal to or smaller in size than the available prefetch size (and also falls into other prefetch limits). May be set to zero, meaning "no specific limit", although other prefetch limits may still apply. The prefetch-size is ignored if the no-ack option is set.

**Rule 01**

The server MUST ignore this setting when the client is not processing any messages - i.e. the prefetch size does not limit the transfer of single messages to a client, only the sending in advance of more messages while the client still has one or more unacknowledged messages.

> Test scenario: Define a QoS prefetch-size limit and send a single message that exceeds that limit.  Verify that the message arrives correctly.

#### basic.qos prefetch-count

Specifies a prefetch window in terms of whole messages. This field may be used in combination with the prefetch-size field; a message will only be sent in advance if both prefetch windows (and those at the channel and connection level) allow it. The prefetch-count is ignored if the no-ack option is set.

**Rule 01**

The server may send less data in advance than allowed by the client's specified prefetch windows but it MUST NOT send more.

> Test scenario: Define a QoS prefetch-size limit and a prefetch-count limit greater than one.  Send multiple messages that exceed the prefetch size.  Verify that no more than one message arrives at once.

#### basic.qos global

RabbitMQ has reinterpreted this field. The original specification said: "By default the QoS settings apply to the current channel only. If this field is set, they are applied to the entire connection." Instead, RabbitMQ takes global=false to mean that the QoS settings should apply per-consumer (for new consumers on the channel; existing ones being unaffected) and global=true to mean that the QoS settings should apply per-channel.

### basic.qos-ok

Method id 60.11: confirm the requested qos.

This method tells the client that the requested QoS levels could be handled by the server. The requested QoS applies to all active consumers until a new QoS is defined.

Implemented by: client MUST. Synchronous.

### basic.consume

Method id 60.20: start a queue consumer.

This method asks the server to start a "consumer", which is a transient request for messages from a specific queue. Consumers last as long as the channel they were declared on, or until the client cancels them.

Implemented by: server MUST. Synchronous, responses: `basic.consume-ok`.

**Rule 01**

The server SHOULD support at least 16 consumers per queue, and ideally, impose no limit except as defined by available resources.

> Test scenario: Declare a queue and create consumers on that queue until the server closes the connection. Verify that the number of consumers created was at least sixteen and report the total number.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| consumer-tag | consumer-tag | consumer tag |
| no-local | no-local | do not deliver own messages |
| no-ack | no-ack | no acknowledgement needed |
| exclusive | bit | request exclusive access |
| no-wait | no-wait | do not send reply method |
| arguments | table | arguments for declaration |

#### basic.consume queue

Specifies the name of the queue to consume from.

#### basic.consume consumer-tag

Specifies the identifier for the consumer. The consumer tag is local to a channel, so two clients can use the same consumer tags. If this field is empty the server will generate a unique tag.

**Rule 01** (on failure: `not-allowed`)

The client MUST NOT specify a tag that refers to an existing consumer.

> Test scenario: Attempt to create two consumers with the same non-empty tag, on the same channel.

**Rule 02** (on failure: `not-allowed`)

The consumer tag is valid only within the channel from which the consumer was created. I.e. a client MUST NOT create a consumer in one channel and then use it in another.

> Test scenario: Attempt to create a consumer in one channel, then use in another channel, in which consumers have also been created (to test that the server uses unique consumer tags).

#### basic.consume exclusive

Request exclusive consumer access, meaning only this consumer can access the queue.

**Rule 01** (on failure: `access-refused`)

The client MAY NOT gain exclusive access to a queue that already has active consumers.

> Test scenario: Open two connections to a server, and in one connection declare a shared (non-exclusive) queue and then consume from the queue.  In the second connection attempt to consume from the same queue using the exclusive option.

#### basic.consume arguments

A set of arguments for the consume. The syntax and semantics of these arguments depends on the server implementation.

### basic.consume-ok

Method id 60.21: confirm a new consumer.

The server provides the client with a consumer tag, which is used by the client for methods called on the consumer at a later stage.

Implemented by: client MUST. Synchronous.

| Field | Domain | Label |
|----|----|----|
| consumer-tag | consumer-tag | consumer tag |

#### basic.consume-ok consumer-tag

Holds the consumer tag specified by the client or provided by the server.

### basic.cancel

Method id 60.30: end a queue consumer.

This method cancels a consumer. This does not affect already delivered messages, but it does mean the server will not send any more messages for that consumer. The client may receive an arbitrary number of messages in between sending the cancel method and receiving the cancel-ok reply.

It may also be sent from the server to the client in the event of the consumer being unexpectedly cancelled (i.e. cancelled for any reason other than the server receiving the corresponding basic.cancel from the client). This allows clients to be notified of the loss of consumers due to events such as queue deletion. Note that as it is not a MUST for clients to accept this method from the server, it is advisable for the broker to be able to identify those clients that are capable of accepting the method, through some means of capability negotiation.

Implemented by: server MUST, client SHOULD. Synchronous, responses: `basic.cancel-ok`.

**Rule 01**

If the queue does not exist the server MUST ignore the cancel method, so long as the consumer tag is valid for that channel.

> Test scenario: TODO.

| Field | Domain | Label |
|----|----|----|
| consumer-tag | consumer-tag | consumer tag |
| no-wait | no-wait | do not send reply method |

### basic.cancel-ok

Method id 60.31: confirm a cancelled consumer.

This method confirms that the cancellation was completed.

Implemented by: client MUST, server MAY. Synchronous.

| Field | Domain | Label |
|----|----|----|
| consumer-tag | consumer-tag | consumer tag |

### basic.publish

Method id 60.40: publish a message.

This method publishes a message to a specific exchange. The message will be routed to queues as defined by the exchange configuration and distributed to any active consumers when the transaction, if any, is committed.

Implemented by: server MUST. Carries content.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| exchange | exchange-name | exchange name |
| routing-key | shortstr | Message routing key |
| mandatory | bit | indicate mandatory routing |
| immediate | bit | request immediate delivery |

#### basic.publish exchange

Specifies the name of the exchange to publish to. The exchange name can be empty, meaning the default exchange. If the exchange name is specified, and that exchange does not exist, the server will raise a channel exception.

**Rule must-exist** (on failure: `not-found`)

The client MUST NOT attempt to publish a content to an exchange that does not exist.

> Test scenario: The client attempts to publish a content to a non-existent exchange.

**Rule default-exchange**

The server MUST accept a blank exchange name to mean the default exchange.

> Test scenario: The client declares a queue and binds it to a blank exchange name.

**Rule 02**

If the exchange was declared as an internal exchange, the server MUST raise a channel exception with a reply code 403 (access refused).

> Test scenario: TODO.

**Rule 03**

The exchange MAY refuse basic content in which case it MUST raise a channel exception with reply code 540 (not implemented).

> Test scenario: TODO.

#### basic.publish routing-key

Specifies the routing key for the message. The routing key is used for routing messages depending on the exchange configuration.

#### basic.publish mandatory

This flag tells the server how to react if the message cannot be routed to a queue. If this flag is set, the server will return an unroutable message with a Return method. If this flag is zero, the server silently drops the message.

**Rule 01**

The server SHOULD implement the mandatory flag.

> Test scenario: TODO.

#### basic.publish immediate

This flag tells the server how to react if the message cannot be routed to a queue consumer immediately. If this flag is set, the server will return an undeliverable message with a Return method. If this flag is zero, the server will queue the message, but with no guarantee that it will ever be consumed.

**Rule 01**

The server SHOULD implement the immediate flag.

> Test scenario: TODO.

### basic.return

Method id 60.50: return a failed message.

This method returns an undeliverable message that was published with the "immediate" flag set, or an unroutable message published with the "mandatory" flag set. The reply code and text provide information about the reason that the message was undeliverable.

Implemented by: client MUST. Carries content.

| Field | Domain | Label |
|----|----|----|
| reply-code | reply-code | reply code from server |
| reply-text | reply-text | localised reply text |
| exchange | exchange-name | exchange name |
| routing-key | shortstr | Message routing key |

#### basic.return exchange

Specifies the name of the exchange that the message was originally published to.  May be empty, meaning the default exchange.

#### basic.return routing-key

Specifies the routing key name specified when the message was published.

### basic.deliver

Method id 60.60: notify the client of a consumer message.

This method delivers a message to the client, via a consumer. In the asynchronous message delivery model, the client starts a consumer using the Consume method, then the server responds with Deliver methods as and when messages arrive for that consumer.

Implemented by: client MUST. Carries content.

**Rule 01**

The server SHOULD track the number of times a message has been delivered to clients and when a message is redelivered a certain number of times - e.g. 5 times - without being acknowledged, the server SHOULD consider the message to be unprocessable (possibly causing client applications to abort), and move the message to a dead letter queue.

> Test scenario: TODO.

| Field | Domain | Label |
|----|----|----|
| consumer-tag | consumer-tag | consumer tag |
| delivery-tag | delivery-tag | server-assigned delivery tag |
| redelivered | redelivered | message is being redelivered |
| exchange | exchange-name | exchange name |
| routing-key | shortstr | Message routing key |

#### basic.deliver exchange

Specifies the name of the exchange that the message was originally published to. May be empty, indicating the default exchange.

#### basic.deliver routing-key

Specifies the routing key name specified when the message was published.

### basic.get

Method id 60.70: direct access to a queue.

This method provides a direct access to the messages in a queue using a synchronous dialogue that is designed for specific types of application where synchronous functionality is more important than performance.

Implemented by: server MUST. Synchronous, responses: `basic.get-ok`, `basic.get-empty`.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | short | reserved |
| queue | queue-name | queue name |
| no-ack | no-ack | no acknowledgement needed |

#### basic.get queue

Specifies the name of the queue to get a message from.

### basic.get-ok

Method id 60.71: provide client with a message.

This method delivers a message to the client following a get method. A message delivered by 'get-ok' must be acknowledged unless the no-ack option was set in the get method.

Implemented by: client MAY. Synchronous. Carries content.

| Field | Domain | Label |
|----|----|----|
| delivery-tag | delivery-tag | server-assigned delivery tag |
| redelivered | redelivered | message is being redelivered |
| exchange | exchange-name | exchange name |
| routing-key | shortstr | Message routing key |
| message-count | message-count | number of messages in queue |

#### basic.get-ok exchange

Specifies the name of the exchange that the message was originally published to. If empty, the message was published to the default exchange.

#### basic.get-ok routing-key

Specifies the routing key name specified when the message was published.

### basic.get-empty

Method id 60.72: indicate no messages available.

This method tells the client that the queue has no messages available for the client.

Implemented by: client MAY. Synchronous.

| Field | Domain | Label |
|----|----|----|
| reserved-1 | shortstr | reserved |

### basic.ack

Method id 60.80: acknowledge one or more messages.

When sent by the client, this method acknowledges one or more messages delivered via the Deliver or Get-Ok methods.

When sent by server, this method acknowledges one or more messages published with the Publish method on a channel in confirm mode.

The acknowledgement can be for a single message or a set of messages up to and including a specific message.

Implemented by: server MUST, client MUST.

| Field | Domain | Label |
|----|----|----|
| delivery-tag | delivery-tag | server-assigned delivery tag |
| multiple | bit | acknowledge multiple messages |

#### basic.ack multiple

If set to 1, the delivery tag is treated as "up to and including", so that multiple messages can be acknowledged with a single method. If set to zero, the delivery tag refers to a single message. If the multiple field is 1, and the delivery tag is zero, this indicates acknowledgement of all outstanding messages.

**Rule exists** (on failure: `precondition-failed`)

A message MUST not be acknowledged more than once.  The receiving peer MUST validate that a non-zero delivery-tag refers to a delivered message, and raise a channel exception if this is not the case. On a transacted channel, this check MUST be done immediately and not delayed until a Tx.Commit.

> Test scenario: TODO.

### basic.reject

Method id 60.90: reject an incoming message.

This method allows a client to reject a message. It can be used to interrupt and cancel large incoming messages, or return untreatable messages to their original queue.

Implemented by: server MUST.

**Rule 01**

The server SHOULD be capable of accepting and process the Reject method while sending message content with a Deliver or Get-Ok method. I.e. the server should read and process incoming methods while sending output frames. To cancel a partially-send content, the server sends a content body frame of size 1 (i.e. with no data except the frame-end octet).

**Rule 02**

The server SHOULD interpret this method as meaning that the client is unable to process the message at this time.

> Test scenario: TODO.

**Rule 03**

The client MUST NOT use this method as a means of selecting messages to process.

> Test scenario: TODO.

| Field | Domain | Label |
|----|----|----|
| delivery-tag | delivery-tag | server-assigned delivery tag |
| requeue | bit | requeue the message |

#### basic.reject requeue

If requeue is true, the server will attempt to requeue the message.  If requeue is false or the requeue  attempt fails the messages are discarded or dead-lettered.

**Rule 01**

The server MUST NOT deliver the message to the same client within the context of the current channel. The recommended strategy is to attempt to deliver the message to an alternative consumer, and if that is not possible, to move the message to a dead-letter queue. The server MAY use more sophisticated tracking to hold the message on the queue and redeliver it to the same client at a later stage.

> Test scenario: TODO.

### basic.recover-async

Method id 60.100: redeliver unacknowledged messages.

This method asks the server to redeliver all unacknowledged messages on a specified channel. Zero or more messages may be redelivered.  This method is deprecated in favour of the synchronous Recover/Recover-Ok.

Implemented by: server MAY.

**Rule 01**

The server MUST set the redelivered flag on all messages that are resent.

> Test scenario: TODO.

| Field | Domain | Label |
|----|----|----|
| requeue | bit | requeue the message |

#### basic.recover-async requeue

If this field is zero, the message will be redelivered to the original recipient. If this bit is 1, the server will attempt to requeue the message, potentially then delivering it to an alternative subscriber.

### basic.recover

Method id 60.110: redeliver unacknowledged messages.

This method asks the server to redeliver all unacknowledged messages on a specified channel. Zero or more messages may be redelivered.  This method replaces the asynchronous Recover.

Implemented by: server MUST.

**Rule 01**

The server MUST set the redelivered flag on all messages that are resent.

> Test scenario: TODO.

| Field | Domain | Label |
|----|----|----|
| requeue | bit | requeue the message |

#### basic.recover requeue

If this field is zero, the message will be redelivered to the original recipient. If this bit is 1, the server will attempt to requeue the message, potentially then delivering it to an alternative subscriber.

### basic.recover-ok

Method id 60.111: confirm recovery.

This method acknowledges a Basic.Recover method.

Implemented by: client MUST. Synchronous.

### basic.nack

Method id 60.120: reject one or more incoming messages.

*RabbitMQ extension.*

This method allows a client to reject one or more incoming messages. It can be used to interrupt and cancel large incoming messages, or return untreatable messages to their original queue.

This method is also used by the server to inform publishers on channels in confirm mode of unhandled messages.  If a publisher receives this method, it probably needs to republish the offending messages.

Implemented by: server MUST, client MUST.

**Rule 01**

The server SHOULD be capable of accepting and processing the Nack method while sending message content with a Deliver or Get-Ok method. I.e. the server should read and process incoming methods while sending output frames. To cancel a partially-send content, the server sends a content body frame of size 1 (i.e. with no data except the frame-end octet).

**Rule 02**

The server SHOULD interpret this method as meaning that the client is unable to process the message at this time.

> Test scenario: TODO.

**Rule 03**

The client MUST NOT use this method as a means of selecting messages to process.

> Test scenario: TODO.

**Rule 04**

A client publishing messages to a channel in confirm mode SHOULD be capable of accepting and somehow handling the Nack method.

> Test scenario: TODO

| Field | Domain | Label |
|----|----|----|
| delivery-tag | delivery-tag | server-assigned delivery tag |
| multiple | bit | reject multiple messages |
| requeue | bit | requeue the message |

#### basic.nack multiple

If set to 1, the delivery tag is treated as "up to and including", so that multiple messages can be rejected with a single method. If set to zero, the delivery tag refers to a single message. If the multiple field is 1, and the delivery tag is zero, this indicates rejection of all outstanding messages.

**Rule exists** (on failure: `precondition-failed`)

A message MUST not be rejected more than once.  The receiving peer MUST validate that a non-zero delivery-tag refers to an unacknowledged, delivered message, and raise a channel exception if this is not the case.

> Test scenario: TODO.

#### basic.nack requeue

If requeue is true, the server will attempt to requeue the message.  If requeue is false or the requeue  attempt fails the messages are discarded or dead-lettered. Clients receiving the Nack methods should ignore this flag.

**Rule 01**

The server MUST NOT deliver the message to the same client within the context of the current channel. The recommended strategy is to attempt to deliver the message to an alternative consumer, and if that is not possible, to move the message to a dead-letter queue. The server MAY use more sophisticated tracking to hold the message on the queue and redeliver it to the same client at a later stage.

> Test scenario: TODO.

## tx

Class id 90: work with transactions.

The Tx class allows publish and ack operations to be batched into atomic units of work.  The intention is that all publish and ack requests issued within a transaction will complete successfully or none of them will. Servers SHOULD implement atomic transactions at least where all publish or ack requests affect a single queue.  Transactions that cover multiple queues may be non-atomic, given that queues can be created and destroyed asynchronously, and such events do not form part of any transaction. Further, the behaviour of transactions with respect to the immediate and mandatory flags on Basic.Publish methods is not defined.

```text
tx                  = C:SELECT S:SELECT-OK
                    / C:COMMIT S:COMMIT-OK
                    / C:ROLLBACK S:ROLLBACK-OK
```

Implemented by: server SHOULD, client MAY.

**Rule not multiple queues**

Applications MUST NOT rely on the atomicity of transactions that affect more than one queue.

**Rule not immediate**

Applications MUST NOT rely on the behaviour of transactions that include messages published with the immediate option.

**Rule not mandatory**

Applications MUST NOT rely on the behaviour of transactions that include messages published with the mandatory option.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [tx.select](#txselect) | 10 | yes | select-ok | select standard transaction mode |
| [tx.select-ok](#txselect-ok) | 11 | yes |  | confirm transaction mode |
| [tx.commit](#txcommit) | 20 | yes | commit-ok | commit the current transaction |
| [tx.commit-ok](#txcommit-ok) | 21 | yes |  | confirm a successful commit |
| [tx.rollback](#txrollback) | 30 | yes | rollback-ok | abandon the current transaction |
| [tx.rollback-ok](#txrollback-ok) | 31 | yes |  | confirm successful rollback |

### tx.select

Method id 90.10: select standard transaction mode.

This method sets the channel to use standard transactions. The client must use this method at least once on a channel before using the Commit or Rollback methods.

Implemented by: server MUST. Synchronous, responses: `tx.select-ok`.

### tx.select-ok

Method id 90.11: confirm transaction mode.

This method confirms to the client that the channel was successfully set to use standard transactions.

Implemented by: client MUST. Synchronous.

### tx.commit

Method id 90.20: commit the current transaction.

This method commits all message publications and acknowledgments performed in the current transaction.  A new transaction starts immediately after a commit.

Implemented by: server MUST. Synchronous, responses: `tx.commit-ok`.

**Rule transacted** (on failure: `precondition-failed`)

The client MUST NOT use the Commit method on non-transacted channels.

> Test scenario: The client opens a channel and then uses Tx.Commit.

### tx.commit-ok

Method id 90.21: confirm a successful commit.

This method confirms to the client that the commit succeeded. Note that if a commit fails, the server raises a channel exception.

Implemented by: client MUST. Synchronous.

### tx.rollback

Method id 90.30: abandon the current transaction.

This method abandons all message publications and acknowledgments performed in the current transaction. A new transaction starts immediately after a rollback. Note that unacked messages will not be automatically redelivered by rollback; if that is required an explicit recover call should be issued.

Implemented by: server MUST. Synchronous, responses: `tx.rollback-ok`.

**Rule transacted** (on failure: `precondition-failed`)

The client MUST NOT use the Rollback method on non-transacted channels.

> Test scenario: The client opens a channel and then uses Tx.Rollback.

### tx.rollback-ok

Method id 90.31: confirm successful rollback.

This method confirms to the client that the rollback succeeded. Note that if an rollback fails, the server raises a channel exception.

Implemented by: client MUST. Synchronous.

## confirm

Class id 85: work with confirms.

The Confirm class allows publishers to put the channel in confirm mode and subsequently be notified when messages have been handled by the broker.  The intention is that all messages published on a channel in confirm mode will be acknowledged at some point.  By acknowledging a message the broker assumes responsibility for it and indicates that it has done something it deems reasonable with it.

Unroutable mandatory or immediate messages are acknowledged right after the Basic.Return method. Messages are acknowledged when all queues to which the message has been routed have either delivered the message and received an acknowledgement (if required), or enqueued the message (and persisted it if required).

Published messages are assigned ascending sequence numbers, starting at 1 with the first Confirm.Select method. The server confirms messages by sending Basic.Ack methods referring to these sequence numbers.

```text
confirm            = C:SELECT S:SELECT-OK
```

Implemented by: server SHOULD, client MAY.

**Rule all messages acknowledged**

The server MUST acknowledge all messages received after the channel was put into confirm mode.

**Rule all queues**

The server MUST acknowledge a message only after it was properly handled by all the queues it was delivered to.

**Rule unroutable messages**

The server MUST acknowledge an unroutable mandatory or immediate message only after it sends the Basic.Return.

**Rule time guarantees**

No guarantees are made as to how soon a message is acknowledged.  Applications SHOULD NOT make assumptions about this.

| Method | Id | Synchronous | Response | Label |
|----|----|----|----|----|
| [confirm.select](#confirmselect) | 10 | yes | select-ok |  (RabbitMQ extension) |
| [confirm.select-ok](#confirmselect-ok) | 11 | yes |  |  (RabbitMQ extension) |

### confirm.select

Method id 85.10: .

*RabbitMQ extension.*

This method sets the channel to use publisher acknowledgements. The client can only use this method on a non-transactional channel.

Implemented by: server MUST. Synchronous, responses: `confirm.select-ok`.

| Field | Domain | Label |
|----|----|----|
| nowait | no-wait | do not send reply method |

### confirm.select-ok

Method id 85.11: .

*RabbitMQ extension.*

This method confirms to the client that the channel was successfully set to use publisher acknowledgements.

Implemented by: client MUST. Synchronous.
