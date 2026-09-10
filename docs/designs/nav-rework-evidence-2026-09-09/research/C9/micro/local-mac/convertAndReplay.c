N_LIB_PRIVATE N_NIMCALL(void, convertAndReplay__bench95danger95lazy95list_u4678)(tyObject_BodyNavSeatcolonObjectType___Uc8v9aEG9ag64r1QaUbvXJng* seat_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p1, NI base_p2, tyObject_ListStore__CLbBNJfvhiylv1GHDNX5Gw* store_p3, NI listIndex_p4) {
	NI radius_1;
	NI diameter_1;
	NI TM__W7aMY615OVJySGXx9cwCHLQ_221;
	NI TM__W7aMY615OVJySGXx9cwCHLQ_222;
	NI gridW_1;
	NI outBase_1;
	NI TM__W7aMY615OVJySGXx9cwCHLQ_223;
	NI count_1;
NIM_BOOL* nimErr_;
	nimfr_("convertAndReplay", "bench_danger_lazy_list.nim");
{nimErr_ = nimErrorFlag();
	radius_1 = (*(*seat_p0).dangerGeometry).radius;
	if (nimMulInt(radius_1, ((NI)2), &TM__W7aMY615OVJySGXx9cwCHLQ_221)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_221), ((NI)1), &TM__W7aMY615OVJySGXx9cwCHLQ_222)) { raiseOverflow(); goto BeforeRet_;
	};
	diameter_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_222);
	gridW_1 = (*seat_p0).danger.gridW;
	if (nimMulInt(listIndex_p4, (*store_p3).capacity, &TM__W7aMY615OVJySGXx9cwCHLQ_223)) { raiseOverflow(); goto BeforeRet_;
	};
	outBase_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_223);
	count_1 = ((NI)0);
	{
		NI wordIndex_1;
		NI i_1;
		wordIndex_1 = (NI)0;
		i_1 = ((NI)0);
		{
			while (1) {
				NU64 word_1;
				NI TM__W7aMY615OVJySGXx9cwCHLQ_224;
				NI TM__W7aMY615OVJySGXx9cwCHLQ_238;
				if (!(i_1 < (*(*seat_p0).dangerSourceCache).words)) goto LA3;
				wordIndex_1 = i_1;
				if (nimAddInt(base_p2, wordIndex_1, &TM__W7aMY615OVJySGXx9cwCHLQ_224)) { raiseOverflow(); goto BeforeRet_;
				};
				if ((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_224) < 0 || (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_224) >= (*(*seat_p0).dangerSourceCache).bits.len){ raiseIndexError2((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_224),(*(*seat_p0).dangerSourceCache).bits.len-1); goto BeforeRet_;
				}
				word_1 = (*(*seat_p0).dangerSourceCache).bits.p->data[(NI)(TM__W7aMY615OVJySGXx9cwCHLQ_224)];
				{
					while (1) {
						NI kernelIndex_1;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_225;
						NI T6_;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_226;
						NI kernelY_1;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_227;
						NI kernelX_1;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_228;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_229;
						NI gridIndex_1;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_230;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_231;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_232;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_233;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_234;
						NI TM__W7aMY615OVJySGXx9cwCHLQ_235;
						NF32 weight_1;
						if (!!((word_1 == 0ULL))) goto LA5;
						if (nimMulInt(wordIndex_1, ((NI)64), &TM__W7aMY615OVJySGXx9cwCHLQ_225)) { raiseOverflow(); goto BeforeRet_;
						};
						T6_ = (NI)0;
						T6_ = countTrailingZeroBits__OOZOOZOOZOOZOOZOnimbyZpkgsZzippyZsrcZzippyZinternal_u471(word_1);
						if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
						if (nimAddInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_225), T6_, &TM__W7aMY615OVJySGXx9cwCHLQ_226)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelIndex_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_226);
						if (diameter_1 == 0){ raiseDivByZero(); goto BeforeRet_;
						}
						if (nimDivInt(kernelIndex_1, diameter_1, &TM__W7aMY615OVJySGXx9cwCHLQ_227)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelY_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_227);
						if (nimMulInt(kernelY_1, diameter_1, &TM__W7aMY615OVJySGXx9cwCHLQ_228)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimSubInt(kernelIndex_1, (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_228), &TM__W7aMY615OVJySGXx9cwCHLQ_229)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelX_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_229);
						if (nimSubInt(origin_p1.Field1, radius_1, &TM__W7aMY615OVJySGXx9cwCHLQ_230)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_230), kernelY_1, &TM__W7aMY615OVJySGXx9cwCHLQ_231)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimMulInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_231), gridW_1, &TM__W7aMY615OVJySGXx9cwCHLQ_232)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_232), origin_p1.Field0, &TM__W7aMY615OVJySGXx9cwCHLQ_233)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimSubInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_233), radius_1, &TM__W7aMY615OVJySGXx9cwCHLQ_234)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_234), kernelX_1, &TM__W7aMY615OVJySGXx9cwCHLQ_235)) { raiseOverflow(); goto BeforeRet_;
						};
						gridIndex_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_235);
						if (kernelIndex_1 < 0 || kernelIndex_1 >= (*(*seat_p0).dangerGeometry).kernel.len){ raiseIndexError2(kernelIndex_1,(*(*seat_p0).dangerGeometry).kernel.len-1); goto BeforeRet_;
						}
						weight_1 = (*(*seat_p0).dangerGeometry).kernel.p->data[kernelIndex_1];
						if (gridIndex_1 < 0 || gridIndex_1 >= (*seat_p0).danger.values.len){ raiseIndexError2(gridIndex_1,(*seat_p0).danger.values.len-1); goto BeforeRet_;
						}
						pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[gridIndex_1]), weight_1);
						{
							NI32 colontmpD_;
							NI TM__W7aMY615OVJySGXx9cwCHLQ_236;
							tyObject_ListEntry__J0WS86jeI1rcPVztV7pfag T11_;
							NI TM__W7aMY615OVJySGXx9cwCHLQ_237;
							if (!!((weight_1 == 0.0f))) goto LA9_;
							colontmpD_ = (NI32)0;
							if (nimAddInt(outBase_1, count_1, &TM__W7aMY615OVJySGXx9cwCHLQ_236)) { raiseOverflow(); goto BeforeRet_;
							};
							if ((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_236) < 0 || (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_236) >= (*store_p3).entries.len){ raiseIndexError2((NI)(TM__W7aMY615OVJySGXx9cwCHLQ_236),(*store_p3).entries.len-1); goto BeforeRet_;
							}
							if ((gridIndex_1) < ((NI32)(-2147483647 -1)) || (gridIndex_1) > ((NI32)2147483647)){ raiseRangeErrorI(gridIndex_1, ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto BeforeRet_;
							}
							colontmpD_ = ((NI32) (gridIndex_1));
							T11_.gridIndex = colontmpD_;
							T11_.weight = weight_1;
							(*store_p3).entries.p->data[(NI)(TM__W7aMY615OVJySGXx9cwCHLQ_236)] = T11_;
							if (nimAddInt(count_1, ((NI)1), &TM__W7aMY615OVJySGXx9cwCHLQ_237)) { raiseOverflow(); goto BeforeRet_;
							};
							count_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_237);
						}
LA9_: ;
						word_1 = (NU64)(word_1 & (NU64)((NU64)(word_1) - (NU64)(1ULL)));
					} LA5: ;
				}
				if (nimAddInt(i_1, ((NI)1), &TM__W7aMY615OVJySGXx9cwCHLQ_238)) { raiseOverflow(); goto BeforeRet_;
				};
				i_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_238);
			} LA3: ;
		}
	}
	if (listIndex_p4 < 0 || listIndex_p4 >= (*store_p3).lengths.len){ raiseIndexError2(listIndex_p4,(*store_p3).lengths.len-1); goto BeforeRet_;
	}
	if ((count_1) < ((NI32)(-2147483647 -1)) || (count_1) > ((NI32)2147483647)){ raiseRangeErrorI(count_1, ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto BeforeRet_;
	}
	(*store_p3).lengths.p->data[listIndex_p4] = ((NI32) (count_1));
	}BeforeRet_: ;
	popFrame();
}